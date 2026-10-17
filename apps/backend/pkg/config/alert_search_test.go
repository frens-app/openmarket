package config

import "testing"

func TestAlertSearchOptions(t *testing.T) {
	for _, raw := range []string{"", "{}"} {
		got, err := ParseAlertSearchOptions(raw)
		if err != nil || got.Sort != "creation_time_descend" || got.MinPrice != nil || got.MaxPrice != nil || got.DaysSinceListed != 0 {
			t.Fatalf("defaults: %+v, %v", got, err)
		}
	}
	got, err := ParseAlertSearchOptions(`{"sort":"price_ascend","delivery":"local_pick_up","daysSinceListed":1,"conditions":["used_good"],"minPrice":0,"maxPrice":100}`)
	if err != nil || got.Sort != "price_ascend" || got.Delivery != "local_pick_up" || got.DaysSinceListed != 1 || len(got.Conditions) != 1 || got.MinPrice == nil || *got.MinPrice != 0 || got.MaxPrice == nil || *got.MaxPrice != 100 {
		t.Fatalf("overrides: %+v, %v", got, err)
	}
	for _, raw := range []string{
		`null`, `[]`, `{} {}`, `{"sort":"typo"}`, `{"delivery":"typo"}`,
		`{"daysSinceListed":2}`, `{"conditions":["typo"]}`, `{"minPrice":-1}`,
		`{"maxPrice":2147483648}`, `{"minPrice":1.5}`, `{"minPrice":50,"maxPrice":20}`,
		`{"maxPages":10}`, `{"min_price":10}`,
	} {
		t.Run(raw, func(t *testing.T) {
			if _, err := ParseAlertSearchOptions(raw); err == nil {
				t.Fatal("accepted invalid search configuration")
			}
		})
	}
}
