package main

import (
	"context"
	"time"

	"connectrpc.com/connect"
	"go.uber.org/zap"
)

// newLoggingInterceptor logs one line per RPC.
//
// Request and response messages are never logged: on this service they carry
// phone numbers and session tokens, and a log aggregator is the last place
// either belongs.
func newLoggingInterceptor(logger *zap.Logger) connect.UnaryInterceptorFunc {
	return func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			start := time.Now()
			resp, err := next(ctx, req)

			fields := []zap.Field{
				zap.String("procedure", req.Spec().Procedure),
				zap.Duration("duration", time.Since(start)),
			}
			if err != nil {
				code := connect.CodeOf(err)
				fields = append(fields, zap.String("code", code.String()), zap.Error(err))
				// Client-caused codes are expected traffic — a wrong
				// verification code is not an incident. Only server-side
				// failures rise to error level so alerting on them stays
				// meaningful.
				switch code {
				case connect.CodeInternal, connect.CodeUnknown, connect.CodeDataLoss, connect.CodeUnavailable:
					logger.Error("rpc failed", fields...)
				default:
					logger.Info("rpc rejected", fields...)
				}
				return resp, err
			}

			logger.Info("rpc", fields...)
			return resp, nil
		}
	}
}
