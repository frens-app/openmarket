package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/grpcreflect"
	"connectrpc.com/validate"
	"frens.lol/openmarket/backend/pkg/config"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/llm"
	"frens.lol/openmarket/backend/pkg/phone"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"frens.lol/openmarket/backend/pkg/verify"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"go.uber.org/zap"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

// Migrations run from the binary at boot rather than as a separate release
// step. On Railway there is no pre-deploy hook that is guaranteed to run
// exactly once before the new container serves traffic, and goose takes an
// advisory lock, so concurrent instances racing this is safe.
const migrationsDir = "deployments/migrations"

const (
	shutdownGrace       = 15 * time.Second
	readHeaderTimeout   = 10 * time.Second
	verificationPruneAt = time.Hour
)

func main() {
	cfg := config.LoadAPI()
	logger := config.NewLogger(cfg)
	defer func() { _ = logger.Sync() }()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		logger.Fatal("connect to database", zap.Error(err))
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		logger.Fatal("ping database", zap.Error(err))
	}

	if err := runMigrations(pool, logger); err != nil {
		logger.Fatal("run migrations", zap.Error(err))
	}

	queries := db.New(pool)

	allowlist, err := phone.NewAllowlist(cfg.AllowedCountryCodes)
	if err != nil {
		logger.Fatal("invalid country allowlist", zap.Error(err))
	}

	sender, err := buildSender(cfg, logger)
	if err != nil {
		logger.Fatal("configure verification sender", zap.Error(err))
	}

	ceiling := &sendCeiling{
		queries: queries,
		max:     cfg.VerificationMaxSends,
		window:  cfg.VerificationSendWindow,
	}

	// Order matters. Validation runs first so a malformed request is rejected
	// before it can touch the session table, then auth, then logging wraps both
	// so a rejection is still one log line.
	interceptors := connect.WithInterceptors(
		newLoggingInterceptor(logger.Named("rpc")),
		validate.NewInterceptor(),
		newAuthInterceptor(cfg.JWTSecret, queries),
	)

	authSvc := &authServer{
		queries:             queries,
		pool:                pool,
		logger:              logger.Named("auth"),
		sender:              sender,
		allowlist:           allowlist,
		ceiling:             ceiling,
		jwtSecret:           cfg.JWTSecret,
		refreshTokenHMACKey: cfg.RefreshTokenHMACKey,
		accessTTL:           cfg.AccessTokenTTL,
		refreshTTL:          cfg.RefreshTokenTTL,
		resendCooldown:      cfg.VerificationResendCooldown,
	}
	userSvc := &userServer{
		queries: queries,
		pool:    pool,
		logger:  logger.Named("user"),
	}
	modelProvider, err := buildModelProvider(cfg)
	if err != nil {
		logger.Fatal("configure model provider", zap.Error(err))
	}
	pricingSvc := &pricingServer{
		queries: queries,
		runner: llm.NewRunner(modelProvider, queries, logger.Named("llm"), llm.Config{
			MaxCallsPerUser: cfg.LLMMaxCallsPerUser,
			Window:          cfg.LLMCallWindow,
			MaxAttempts:     cfg.LLMMaxAttempts,
			Timeout:         cfg.LLMTimeout,
		}),
		logger: logger.Named("pricing"),
	}

	mux := http.NewServeMux()
	mux.Handle(apiv1connect.NewAuthServiceHandler(authSvc, interceptors))
	mux.Handle(apiv1connect.NewUserServiceHandler(userSvc, interceptors))
	mux.Handle(apiv1connect.NewPricingServiceHandler(pricingSvc, interceptors))
	mux.HandleFunc("/health", healthHandler(pool))

	// Reflection is for grpcurl against a local server. Off in production:
	// publishing the full service descriptor to anonymous callers is free
	// reconnaissance for no operational benefit.
	if !cfg.IsProduction() {
		reflector := grpcreflect.NewStaticReflector(
			apiv1connect.AuthServiceName,
			apiv1connect.UserServiceName,
			apiv1connect.PricingServiceName,
		)
		mux.Handle(grpcreflect.NewHandlerV1(reflector))
		mux.Handle(grpcreflect.NewHandlerV1Alpha(reflector))
	}

	srv := &http.Server{
		Addr: fmt.Sprintf(":%d", cfg.Port),
		// h2c so the same handler serves Connect over HTTP/1.1 (what the iOS
		// client uses, on URLSession) and gRPC over cleartext HTTP/2 (what
		// service-to-service callers would use). Railway terminates TLS.
		Handler:           h2c.NewHandler(mux, &http2.Server{}),
		ReadHeaderTimeout: readHeaderTimeout,
	}

	go prunePeriodically(ctx, ceiling, logger.Named("prune"))

	serveErr := make(chan error, 1)
	go func() {
		logger.Info("listening",
			zap.Int("port", cfg.Port),
			zap.Int("bypass_numbers", len(cfg.BypassPhoneNumbers())),
		)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}()

	select {
	case err := <-serveErr:
		logger.Fatal("serve", zap.Error(err))
	case <-ctx.Done():
		logger.Info("shutting down")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Warn("graceful shutdown failed", zap.Error(err))
	}
}

// buildSender always constructs the real Prelude client, then optionally wraps
// it so a few known numbers can skip it. Every environment talks to the real
// Prelude API; development differs from production only in whether that bypass
// list is empty — not in which code runs, and not in who is on the other end.
func buildSender(cfg config.ServiceConfig, logger *zap.Logger) (verify.Sender, error) {
	provider, err := verify.NewPreludeSender(verify.PreludeOptions{
		APIKey:     cfg.PreludeAPIKey,
		CodeLength: cfg.VerificationCodeLength,
	})
	if err != nil {
		return nil, err
	}

	return verify.NewBypassSender(
		cfg.BypassPhoneNumbers(),
		cfg.DevVerificationCode,
		provider,
		logger.Named("verify"),
	)
}

// buildModelProvider selects the vendor behind Price Check.
//
// The stub is a real code path chosen by configuration, the same way the
// verification bypass is — not a test double injected here. config.LoadAPI has
// already refused it under ENV=production and refused a real provider with no
// key, so by this point the choice is known-good and this only has to make it.
func buildModelProvider(cfg config.ServiceConfig) (llm.Provider, error) {
	switch cfg.LLMProvider {
	case config.LLMProviderStub:
		return llm.StubProvider{}, nil
	case config.LLMProviderGoogle:
		return llm.NewGeminiProvider(llm.GeminiOptions{
			APIKey: cfg.LLMAPIKey,
			Model:  cfg.LLMModel,
		})
	default:
		// Never silently the stub. A deployment that believes it is calling a
		// model and is not would serve invented prices that look exactly like
		// real ones.
		return nil, fmt.Errorf("unknown llm_provider %q", cfg.LLMProvider)
	}
}

func runMigrations(pool *pgxpool.Pool, logger *zap.Logger) error {
	sqlDB := stdlib.OpenDBFromPool(pool)
	defer func() { _ = sqlDB.Close() }()

	if err := goose.SetDialect("postgres"); err != nil {
		return fmt.Errorf("set goose dialect: %w", err)
	}
	goose.SetLogger(goose.NopLogger())
	logger.Info("applying migrations", zap.String("dir", migrationsDir))
	if err := goose.Up(sqlDB, migrationsDir); err != nil {
		return fmt.Errorf("goose up: %w", err)
	}
	version, err := goose.GetDBVersion(sqlDB)
	if err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	logger.Info("migrations applied", zap.Int64("version", version))
	return nil
}

func prunePeriodically(ctx context.Context, ceiling *sendCeiling, logger *zap.Logger) {
	ticker := time.NewTicker(verificationPruneAt)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := ceiling.prune(ctx); err != nil {
				logger.Warn("prune verification sends", zap.Error(err))
			}
		}
	}
}

// healthHandler is what Railway polls. It pings the pool rather than returning
// a constant, so a container that has lost its database is replaced instead of
// serving errors.
func healthHandler(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}
}
