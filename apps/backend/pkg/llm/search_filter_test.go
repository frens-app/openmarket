package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"go.uber.org/zap"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSearchFilterMultipartAndFailOpenImages(t *testing.T) {
	for _, choice := range []SearchVerdict{SearchMatch, SearchUnknown, SearchMismatch} {
		t.Run(string(choice), func(t *testing.T) {
			photo := searchTestPNG(560, 280)
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Header.Get("Authorization") != "Bearer test-key" || r.Header.Get("TypeSafe-Danger-Zone-Images") != "true" {
					t.Error("missing direct Jev headers")
				}
				if err := r.ParseMultipartForm(5 << 20); err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				defer r.MultipartForm.RemoveAll()
				request, _, err := r.FormFile("request")
				if err != nil {
					t.Error(err)
					return
				}
				defer request.Close()
				var payload searchFilterRequest
				if err := json.NewDecoder(request).Decode(&payload); err != nil {
					t.Error(err)
					return
				}
				if payload.Model != searchFilterModel || payload.State["query"] != "black standing desk" || len(payload.Questions) != 1 || len(payload.Assets) != 1 {
					t.Errorf("unexpected request: %+v", payload)
				}
				q, ok := payload.Questions["candidate_0"]
				if !ok || q.Type != "choice" || len(q.Criteria) != 3 || !strings.Contains(q.Instructions, `{"title":"desk"}`) || !strings.Contains(q.Instructions, searchFilterPolicy) {
					t.Error("incorrect triage prompt")
				}
				for ref, asset := range payload.Assets {
					if !strings.Contains(q.Instructions, ref) || asset.Type != "image" || asset.Part != "photo-0" {
						t.Error("image not linked to its question")
					}
					f, header, err := r.FormFile(asset.Part)
					if err != nil {
						t.Error(err)
						continue
					}
					raw, _ := io.ReadAll(f)
					f.Close()
					if header.Header.Get("Content-Type") != "image/jpeg" || !bytes.Equal(raw, photo) {
						t.Error("incorrect image part")
					}
				}
				fmt.Fprintf(w, `{"model":"jev-1.14.0","answers":{"candidate_0":{"type":"choice","choice":%q}},"usage":{"input_tokens":1234,"output_tokens":0}}`, choice)
			}))
			defer server.Close()
			j := NewJevSearchFilter("test-key")
			j.endpoint = server.URL
			j.loadImage = func(ctx context.Context, url string) ([]byte, error) {
				if url == "missing" {
					return nil, errors.New("unavailable")
				}
				return photo, nil
			}
			decisions, usage, err := j.FilterSearch(context.Background(), SearchFilterInput{Query: "black standing desk", Candidates: []SearchCandidate{
				{ID: "a", Title: "desk", ImageURL: "photo"}, {ID: "b", Title: "red desk", ImageURL: "missing"}, {ID: "c", Title: "red desk"},
			}})
			if err != nil {
				t.Fatal(err)
			}
			if calls != 1 || len(decisions) != 3 || decisions[0].ID != "a" || decisions[0].Verdict != choice || !decisions[0].ImageUsed {
				t.Fatalf("decisions=%+v calls=%d", decisions, calls)
			}
			for _, d := range decisions[1:] {
				if d.Verdict != SearchUnknown || d.ImageUsed {
					t.Fatalf("failed image must stay unknown: %+v", d)
				}
			}
			if usage.Model != searchFilterModel || usage.InputTokens == nil || *usage.InputTokens != 1234 {
				t.Fatalf("missing usage: %+v", usage)
			}
		})
	}
}

func TestSearchFilterRejectsIncompleteAndInvalidAnswers(t *testing.T) {
	for _, body := range []string{
		`{}`, `{"answers":{"candidate_99":{"type":"choice","choice":"mismatch"}}}`,
		`{"answers":{"candidate_0":{"type":"choice","choice":"reject"}}}`,
		`{"answers":{"candidate_0":{"type":"boolean","choice":"mismatch"}}}`,
		`{"answers":{"candidate_0":{"type":"choice","choice":"match"},"extra":{}}}`, `not-json`,
	} {
		t.Run(body, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, body) }))
			defer server.Close()
			j := NewJevSearchFilter("key")
			j.endpoint = server.URL
			j.loadImage = func(context.Context, string) ([]byte, error) { return []byte("test photo"), nil }
			_, _, err := j.FilterSearch(context.Background(), SearchFilterInput{Query: "desk", Candidates: []SearchCandidate{{ID: "a", ImageURL: "photo"}}})
			if CodeOf(err) != ErrorCodeInvalidOutput {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

func TestSearchFilterSkipsModelWhenNoImagesAreUsable(t *testing.T) {
	j := NewJevSearchFilter("key")
	j.endpoint = ":invalid"
	j.loadImage = func(context.Context, string) ([]byte, error) { return nil, errors.New("bad photo") }
	decisions, _, err := j.FilterSearch(context.Background(), SearchFilterInput{Candidates: []SearchCandidate{{ID: "a", ImageURL: "photo"}}})
	if err != nil || len(decisions) != 1 || decisions[0].Verdict != SearchUnknown || decisions[0].ImageUsed {
		t.Fatalf("decisions=%v err=%v", decisions, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err = j.FilterSearch(ctx, SearchFilterInput{Candidates: []SearchCandidate{{ID: "a"}}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation lost: %v", err)
	}
}

func TestSearchImageURLAndAddressBoundaries(t *testing.T) {
	for _, raw := range []string{"https://scontent.xx.fbcdn.net/v/t1/photo.jpg?token=test", "https://scontent.fbsbx.com/photo", "https://SContent.xx.fbcdn.net:443/photo"} {
		if !validSearchImageURL(raw) {
			t.Errorf("valid URL rejected: %s", raw)
		}
	}
	for _, raw := range []string{"http://a.fbcdn.net/p", "https://fbcdn.net.evil.test/p", "https://evilfbcdn.net/p", "https://a.fbcdn.net:8443/p", "https://user@a.fbcdn.net/p", "https://127.0.0.1/p", "file:///etc/passwd", "https://a.fbcdn.net./p", "https://a.fbcdn.net\\@evil.test/p"} {
		if validSearchImageURL(raw) {
			t.Errorf("unsafe URL accepted: %s", raw)
		}
	}
	for _, raw := range []string{"127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1"} {
		if publicImageIP(net.ParseIP(raw)) {
			t.Errorf("unsafe IP accepted: %s", raw)
		}
	}
	if !publicImageIP(net.ParseIP("157.240.1.1")) {
		t.Error("public IP rejected")
	}
}

func TestSearchImagePreparationBoundsAndAspectRatio(t *testing.T) {
	for _, size := range [][2]int{{1120, 560}, {100, 500}, {500, 100}, {10, 10}} {
		raw, err := prepareSearchImage(searchTestPNG(size[0], size[1]))
		if err != nil {
			t.Fatal(err)
		}
		img, err := jpeg.Decode(bytes.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		b := img.Bounds()
		if b.Dx() < 256 || b.Dy() < 256 || b.Dx() > 560 || b.Dy() > 560 || b.Dx()*b.Dy() < 78400 {
			t.Fatalf("Jev-incompatible size: %v", b)
		}
	}
	if _, err := prepareSearchImage(searchTestPNG(4097, 1)); err == nil {
		t.Error("oversized image accepted")
	}
	if _, err := prepareSearchImage([]byte("not an image")); err == nil {
		t.Error("invalid image accepted")
	}
}

type imageRoundTripper func(*http.Request) (*http.Response, error)

func (f imageRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestSearchImageDownloadLimitsAndRedirects(t *testing.T) {
	for _, tc := range []struct {
		name     string
		status   int
		data     []byte
		location string
	}{
		{"ok", 200, searchTestPNG(280, 280), ""}, {"too-large", 200, make([]byte, (2<<20)+1), ""},
		{"redirect", 302, nil, "http://127.0.0.1/secret"}, {"missing", 404, nil, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			client := &http.Client{CheckRedirect: noImageRedirect, Transport: imageRoundTripper(func(r *http.Request) (*http.Response, error) {
				calls++
				h := http.Header{}
				if tc.location != "" {
					h.Set("Location", tc.location)
				}
				return &http.Response{StatusCode: tc.status, Header: h, Body: io.NopCloser(bytes.NewReader(tc.data)), ContentLength: -1, Request: r}, nil
			})}
			_, err := loadSearchImage(context.Background(), client, "https://scontent.xx.fbcdn.net/photo")
			if (err == nil) != (tc.name == "ok") || calls != 1 {
				t.Fatalf("err=%v calls=%d", err, calls)
			}
			_, err = loadSearchImage(context.Background(), client, "https://example.com/photo")
			if err == nil || calls != 1 {
				t.Fatal("unsupported host reached network")
			}
		})
	}
}

func searchTestPNG(width, height int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	img.Set(0, 0, color.Black)
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes()
}

func TestSearchImageWorkersRespectCancellationAndConcurrencyLimit(t *testing.T) {
	j := NewJevSearchFilter("key")
	var active, peak atomic.Int32
	j.loadImage = func(ctx context.Context, _ string) ([]byte, error) {
		count := active.Add(1)
		defer active.Add(-1)
		for previous := peak.Load(); count > previous; previous = peak.Load() {
			if peak.CompareAndSwap(previous, count) {
				break
			}
		}
		<-ctx.Done()
		return nil, ctx.Err()
	}
	in := SearchFilterInput{Query: "desk"}
	for i := 0; i < 20; i++ {
		in.Candidates = append(in.Candidates, SearchCandidate{ID: fmt.Sprint(i), ImageURL: "photo"})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, _, err := j.FilterSearch(ctx, in)
	if !errors.Is(err, context.DeadlineExceeded) || peak.Load() > 4 || active.Load() != 0 {
		t.Fatalf("err=%v peak=%d active=%d", err, peak.Load(), active.Load())
	}
}

type searchRunnerStub struct{ calls int }

func (*searchRunnerStub) Name() string { return "typesafe" }
func (s *searchRunnerStub) FilterSearch(context.Context, SearchFilterInput) ([]SearchFilterDecision, Usage, error) {
	s.calls++
	return []SearchFilterDecision{{ID: "a", Verdict: SearchUnknown}}, Usage{Model: searchFilterModel, InputTokens: i32(123)}, nil
}
func TestSearchFilterRunnerRecordsUsageAndEnforcesSharedQuota(t *testing.T) {
	store := &fakeStore{count: 1}
	provider := &searchRunnerStub{}
	runner := NewSearchFilterRunner(provider, store, zap.NewNop(), Config{MaxCallsPerUser: 1, Window: time.Hour, MaxAttempts: 1, Timeout: time.Second})
	sub := Subject{UserID: uuid.New()}
	_, err := runner.FilterSearch(context.Background(), sub, SearchFilterInput{})
	if !errors.Is(err, ErrCeilingReached) || provider.calls != 0 {
		t.Fatalf("quota bypassed: %v", err)
	}
	store.count = 0
	_, err = runner.FilterSearch(context.Background(), sub, SearchFilterInput{})
	if err != nil || len(store.runs) != 1 {
		t.Fatalf("err=%v runs=%d", err, len(store.runs))
	}
	run := store.runs[0]
	if run.Provider != "typesafe" || run.Model != searchFilterModel || (run.InputTokens == nil || *run.InputTokens != 123) {
		t.Fatalf("usage not recorded: %+v", run)
	}
}
