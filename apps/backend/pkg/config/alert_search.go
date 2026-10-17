package config

import (
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"strings"
)

type AlertSearchOptions struct {
	Sort            string   `json:"sort"`
	Delivery        string   `json:"delivery"`
	DaysSinceListed int      `json:"daysSinceListed"`
	Conditions      []string `json:"conditions"`
	MinPrice        *int     `json:"minPrice,omitempty"`
	MaxPrice        *int     `json:"maxPrice,omitempty"`
}

func ParseAlertSearchOptions(raw string) (AlertSearchOptions, error) {
	options := AlertSearchOptions{Sort: "creation_time_descend", Conditions: []string{}}
	if strings.TrimSpace(raw) == "" {
		return options, nil
	}
	if !strings.HasPrefix(strings.TrimSpace(raw), "{") {
		return options, fmt.Errorf("expected a JSON object")
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&options); err != nil {
		return options, err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return options, fmt.Errorf("expected exactly one JSON object")
	}
	if !slices.Contains([]string{"best_match", "creation_time_descend", "distance_ascend", "price_ascend", "price_descend"}, options.Sort) {
		return options, fmt.Errorf("unsupported sort %q", options.Sort)
	}
	if !slices.Contains([]string{"", "local_pick_up", "shipping"}, options.Delivery) {
		return options, fmt.Errorf("unsupported delivery %q", options.Delivery)
	}
	if !slices.Contains([]int{0, 1, 7, 30}, options.DaysSinceListed) {
		return options, fmt.Errorf("daysSinceListed must be 0, 1, 7, or 30")
	}
	for _, condition := range options.Conditions {
		if !slices.Contains([]string{"new", "used_like_new", "used_good", "used_fair"}, condition) {
			return options, fmt.Errorf("unsupported condition %q", condition)
		}
	}
	// The Facebook request encodes whole currency units as hundredths.
	for _, price := range []*int{options.MinPrice, options.MaxPrice} {
		if price != nil && (*price < 0 || *price > 2147483647) {
			return options, fmt.Errorf("price bounds must be between 0 and 2147483647")
		}
	}
	if options.MinPrice != nil && options.MaxPrice != nil && *options.MinPrice > *options.MaxPrice {
		return options, fmt.Errorf("minPrice must not exceed maxPrice")
	}
	return options, nil
}
