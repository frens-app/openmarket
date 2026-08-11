package config

import (
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// NewLogger builds the process logger: JSON in production so Railway's log
// viewer can index it, console elsewhere so a laptop is readable.
func NewLogger(cfg ServiceConfig) *zap.Logger {
	level := zap.NewAtomicLevelAt(zapcore.InfoLevel)
	if err := level.UnmarshalText([]byte(cfg.LogLevel)); err != nil {
		level.SetLevel(zapcore.InfoLevel)
	}

	var zcfg zap.Config
	if cfg.IsProduction() {
		zcfg = zap.NewProductionConfig()
	} else {
		zcfg = zap.NewDevelopmentConfig()
		zcfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	}
	zcfg.Level = level

	logger, err := zcfg.Build()
	if err != nil {
		panic(err)
	}
	return logger.With(zap.String("service", "api"), zap.String("env", cfg.Env))
}
