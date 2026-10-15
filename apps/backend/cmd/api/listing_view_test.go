package main

import (
	"context"
	"net/http"
	"testing"
	"time"

	"connectrpc.com/connect"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestListingViewValidation(t *testing.T) {
	now := time.Now()
	valid := &v1.SubmitListingViewRequest{FacebookListingId: "123456789", ViewedAt: timestamppb.New(now)}
	if err := validateListingView(valid, now); err != nil {
		t.Fatal(err)
	}
	fresh := proto.Clone(valid).(*v1.SubmitListingViewRequest)
	fresh.Source = v1.ListingViewSource_LISTING_VIEW_SOURCE_ANONYMOUS_GRAPHQL
	fresh.Snapshot = &v1.SavedListingSnapshot{FacebookListingId: valid.FacebookListingId, Description: proto.String("Desk"), DetailObservedAt: timestamppb.New(now)}
	if err := validateListingView(fresh, now); err != nil {
		t.Fatal(err)
	}
	for name, change := range map[string]func(*v1.SubmitListingViewRequest){
		"future view":              func(r *v1.SubmitListingViewRequest) { r.ViewedAt = timestamppb.New(now.Add(time.Hour)) },
		"missing source":           func(r *v1.SubmitListingViewRequest) { r.Source = 0 },
		"unknown source":           func(r *v1.SubmitListingViewRequest) { r.Source = 99 },
		"wrong listing":            func(r *v1.SubmitListingViewRequest) { r.Snapshot.FacebookListingId = "987654321" },
		"missing observation time": func(r *v1.SubmitListingViewRequest) { r.Snapshot.DetailObservedAt = nil },
		"source without data":      func(r *v1.SubmitListingViewRequest) { r.Snapshot = nil },
	} {
		t.Run(name, func(t *testing.T) {
			r := proto.Clone(fresh).(*v1.SubmitListingViewRequest)
			change(r)
			if validateListingView(r, now) == nil {
				t.Fatal("accepted invalid view")
			}
		})
	}
}

func TestListingViewRequiresAuthentication(t *testing.T) {
	procedure := apiv1connect.ListingViewServiceSubmitListingViewProcedure
	if _, err := authenticate(context.Background(), procedure, http.Header{}, "secret", nil); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("anonymous view accepted", err)
	}
	if _, err := authenticate(context.Background(), procedure, http.Header{"Authorization": {"Bearer invalid"}}, "secret", nil); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("invalid credential accepted", err)
	}
	if _, err := authenticate(context.Background(), apiv1connect.SavedListingServiceListSavedListingsProcedure, http.Header{}, "secret", nil); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("other endpoint became anonymous", err)
	}
}

func TestListingViewHandlerRequiresAuthentication(t *testing.T) {
	server := &listingViewServer{}
	_, err := server.SubmitListingView(context.Background(), connect.NewRequest(&v1.SubmitListingViewRequest{}))
	if connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("anonymous handler call accepted", err)
	}
}
