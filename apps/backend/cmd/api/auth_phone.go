package main

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

// Keep the old RPCs registered so older clients receive an actionable error.
// They never send SMS, verify a code, create an account, or mint a session.
func (s *authServer) GetSignInOptions(context.Context, *connect.Request[v1.GetSignInOptionsRequest]) (*connect.Response[v1.GetSignInOptionsResponse], error) {
	return connect.NewResponse(&v1.GetSignInOptionsResponse{}), nil
}
func phoneSignInRetired() error {
	return connect.NewError(connect.CodeFailedPrecondition, errors.New("phone sign-in is no longer available; update Openmarket to use Apple or Google"))
}
func (s *authServer) StartPhoneVerification(context.Context, *connect.Request[v1.StartPhoneVerificationRequest]) (*connect.Response[v1.StartPhoneVerificationResponse], error) {
	return nil, phoneSignInRetired()
}
func (s *authServer) VerifyPhone(context.Context, *connect.Request[v1.VerifyPhoneRequest]) (*connect.Response[v1.VerifyPhoneResponse], error) {
	return nil, phoneSignInRetired()
}
