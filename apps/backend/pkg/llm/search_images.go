package llm

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	_ "image/png"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

func noImageRedirect(*http.Request, []*http.Request) error {
	return errors.New("redirects are disabled")
}

func validSearchImageURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return strings.HasSuffix(host, ".fbcdn.net") || strings.HasSuffix(host, ".fbsbx.com")
}

func publicImageIP(ip net.IP) bool {
	return ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !ip.IsUnspecified() && !ip.IsMulticast() &&
		!(ip.To4() != nil && ip.To4()[0] == 100 && ip.To4()[1]&0xc0 == 64)
}

func newSearchImageClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.MaxConnsPerHost = 4
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
		if err != nil {
			return nil, err
		}
		if len(ips) == 0 {
			return nil, errors.New("image host has no addresses")
		}
		for _, ip := range ips {
			if !publicImageIP(ip.IP) {
				return nil, errors.New("private image address")
			}
		}
		dialer := net.Dialer{Timeout: 2 * time.Second}
		// Dial the checked address directly so a second DNS answer cannot bypass validation.
		return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
	}
	return &http.Client{Transport: transport, CheckRedirect: noImageRedirect}
}

func loadSearchImage(ctx context.Context, client *http.Client, rawURL string) ([]byte, error) {
	if !validSearchImageURL(rawURL) {
		return nil, errors.New("unsupported headline image host")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New("headline image unavailable")
	}
	const maxBytes = 2 << 20
	if resp.ContentLength > maxBytes {
		return nil, errors.New("headline image too large")
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxBytes {
		return nil, errors.New("headline image too large")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return prepareSearchImage(raw)
}

func prepareSearchImage(raw []byte) ([]byte, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > 4096 || cfg.Height > 4096 || int64(cfg.Width)*int64(cfg.Height) > 4_000_000 {
		return nil, errors.New("headline image dimensions too large")
	}
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	width, height := cfg.Width, cfg.Height
	if width > 560 || height > 560 {
		if width >= height {
			height = max(1, height*560/width)
			width = 560
		} else {
			width = max(1, width*560/height)
			height = 560
		}
	}
	// Jev requires both sides >=256 and area >=78400; padding preserves narrow product proportions.
	dst := image.NewRGBA(image.Rect(0, 0, max(width, 280), max(height, 280)))
	draw.Draw(dst, dst.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	x, y := (dst.Bounds().Dx()-width)/2, (dst.Bounds().Dy()-height)/2
	draw.ApproxBiLinear.Scale(dst, image.Rect(x, y, x+width, y+height), src, src.Bounds(), draw.Over, nil)
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, dst, &jpeg.Options{Quality: 80}); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}
