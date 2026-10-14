package main

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"connectrpc.com/connect"
)

func profileName(raw *string, field string, maxLength int) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	value := strings.TrimSpace(*raw)
	if value == "" {
		return nil, nil
	}
	if utf8.RuneCountInString(value) > maxLength {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("%s is too long", field))
	}
	return &value, nil
}
