---
title: "Content-Encoding: gzip은 누가 붙였을까"
url: "/backend/network/2026/03/07/http-response-compression/"
date: 2026-03-07 09:00:00 +0900
categories: [backend, network]
---

`curl -I`로 API 응답을 봤더니 `Content-Encoding: gzip`이 붙어 있다. 그런데 앱 서버 코드에는 gzip 관련 로직이 없다. 이럴 때 압축은 보통 앱 앞단의 CDN, 리버스 프록시, 서비스 메시 프록시가 담당한다.

HTTP 응답 압축은 두 헤더로 결정된다.

## 두 헤더

| 헤더 | 방향 | 의미 |
|---|---|---|
| `Accept-Encoding` | 요청 | 클라이언트가 풀 수 있는 압축 방식 |
| `Content-Encoding` | 응답 | 서버가 실제 적용한 압축 방식 |

요청은 이렇게 간다.

```http
GET /api/users HTTP/1.1
Accept-Encoding: gzip, br, zstd
```

응답은 이렇게 온다.

```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Encoding: gzip
Vary: Accept-Encoding
```

`Content-Encoding`은 본문이 어떤 방식으로 인코딩됐는지를 말한다. 클라이언트는 이 값을 보고 압축을 푼다. `Content-Length`가 있다면 압축된 뒤의 길이다.

`Vary: Accept-Encoding`도 중요하다. 캐시가 gzip을 지원하는 클라이언트와 지원하지 않는 클라이언트의 응답을 구분하게 해준다. 이 헤더가 없으면 프록시나 CDN 캐시에서 압축된 응답이 엉뚱한 클라이언트에게 갈 수 있다.

## 누가 압축하는가

앱 서버가 직접 압축할 수도 있지만, 운영 환경에서는 앞단에서 처리하는 경우가 많다.

```text
client -> CDN / LB / reverse proxy -> app server
             ^
             여기서 gzip, br, zstd 적용
```

이렇게 두면 압축 설정을 서비스별 코드가 아니라 인프라 정책으로 관리할 수 있고, 정적 파일은 CDN에서 사전 압축본을 제공하기 쉽다.

Nginx라면 대략 이런 설정이 붙는다.

```nginx
gzip on;
gzip_types text/plain application/json application/javascript text/css;
gzip_min_length 1024;
gzip_vary on;
```

작은 응답, 이미지, zip처럼 이미 압축된 파일은 다시 압축해도 이득이 작거나 오히려 손해다. 그래서 타입과 최소 크기를 제한한다.

## 클라이언트는 보통 자동으로 푼다

대부분의 고수준 HTTP 클라이언트는 `Accept-Encoding`을 자동으로 붙이고, 응답도 자동으로 해제한다.

| 클라이언트 | 자동 요청 | 자동 해제 | 비고 |
|---|---|---|---|
| 브라우저 `fetch` | O | O | 사용자가 직접 제어하기 어렵다 |
| Go `net/http` | O | O | 조건부로 gzip 요청 |
| Python `requests` | O | O | urllib3가 해제 |
| Node.js `fetch` | O | O | undici 기반 |
| Node.js `http` | X | X | 직접 처리 필요 |

Go는 사용자가 `Accept-Encoding`을 직접 넣지 않았고, `Range`나 `HEAD` 요청이 아닐 때 자동으로 gzip을 요청한다. 자동 해제된 응답에서는 `Content-Encoding`과 `Content-Length`가 제거되고 `resp.Uncompressed`가 `true`가 된다.

```go
resp, err := http.Get(url)
if err != nil {
    return err
}
defer resp.Body.Close()

fmt.Println(resp.Uncompressed)
fmt.Println(resp.Header.Get("Content-Encoding"))
```

반대로 `Accept-Encoding`을 직접 설정하면 "압축은 내가 다루겠다"는 의미가 된다. 이 경우 응답 body를 직접 `gzip.NewReader` 등으로 풀어야 할 수 있다.

## 방식 선택

| 방식 | 쓸 곳 | 메모 |
|---|---|---|
| gzip | 범용 API | 호환성이 가장 좋다 |
| br | 정적 웹 자산 | 압축률이 좋지만 압축 비용이 크다 |
| zstd | 내부 서비스, 최신 클라이언트 | 속도와 압축률 균형이 좋다 |
| deflate | 피하는 편 | 구현 호환성 이슈가 오래됐다 |

API 응답은 gzip만으로도 충분한 경우가 많다. HTML, CSS, JS 같은 정적 자산은 CDN에서 Brotli 사전 압축본을 제공하는 구성이 흔하다. zstd는 지원 여부를 확인한 뒤 내부 트래픽부터 적용하기 좋다.

## 확인하는 법

압축 협상을 직접 확인하려면 `Accept-Encoding`을 명시한다.

```bash
curl -H 'Accept-Encoding: gzip' -I https://example.com/api
```

압축된 body를 그대로 보고 싶으면 자동 해제를 끈다.

```bash
curl --raw -H 'Accept-Encoding: gzip' https://example.com/api
```

앱 코드에 gzip이 없는데 응답에 `Content-Encoding`이 있다면, 다음 순서로 확인한다.

- CDN의 compression 설정
- 리버스 프록시의 gzip/brotli 설정
- Ingress controller 설정
- Envoy/Istio 같은 service mesh filter
- 앱 미들웨어
