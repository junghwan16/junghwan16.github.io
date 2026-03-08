---
title: "HTTP 응답 압축: 클라이언트와 서버는 어떻게 협상하는가"
url: "/backend/network/2026/03/07/http-response-compression/"
date: 2026-03-07 09:00:00 +0900
categories: [backend, network]
---

> `curl -I`로 API 응답 헤더를 확인하니 `Content-Encoding: gzip`이 붙어 있다. 우리 앱 서버 코드에는 gzip 관련 로직이 전혀 없는데, 누가 압축을 하고 있는 걸까? 그리고 클라이언트는 어떻게 이걸 알아서 풀고 있는 걸까?

---

## HTTP 압축이란

HTTP 압축은 서버가 응답 본문을 압축해서 전송하고, 클라이언트가 이를 풀어서 사용하는 구조다. 원리는 단순한데, **누가 압축하고 누가 푸는지**, 그리고 **양쪽이 어떻게 합의하는지**가 핵심이다.

이 합의 과정을 HTTP 스펙에서는 **Content Negotiation**이라고 부른다. 클라이언트가 "나는 이런 압축을 이해할 수 있다"고 알리고, 서버가 그중 하나를 선택해서 압축하는 구조다.

---

## 두 개의 헤더가 전부다

HTTP 압축에 관여하는 헤더는 딱 두 개다.

### `Accept-Encoding` — 클라이언트의 요청

```
GET /api/users HTTP/1.1
Host: example.com
Accept-Encoding: gzip, deflate, br
```

클라이언트가 지원하는 압축 방식을 나열한다. "나는 gzip, deflate, br을 디코딩할 수 있으니, 이 중 하나로 보내도 된다"는 선언이다.

선호도를 `q` 값으로 표현할 수도 있다:

```
Accept-Encoding: br;q=1.0, gzip;q=0.8, *;q=0.1
```

`q=1.0`이 가장 높은 선호도다. 서버는 이걸 참고해서 최적의 알고리즘을 고를 수 있다. 실제로는 대부분의 서버가 `q` 값을 무시하고 자기가 지원하는 가장 효율적인 방식을 선택한다.

### `Content-Encoding` — 서버의 응답

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Encoding: gzip
Content-Length: 1847
```

서버가 실제로 적용한 인코딩을 알린다. 클라이언트는 이 헤더를 보고 디코딩 방식을 결정한다. 이 헤더가 없으면 본문은 압축되지 않은 원본이다.

**주의할 점**: `Content-Length`는 **압축된 후의 크기**다. 클라이언트가 압축을 풀면 실제 데이터는 이보다 훨씬 클 수 있다. 그리고 실무에서는 서버가 동적으로 압축하면 최종 크기를 미리 알 수 없어 `Transfer-Encoding: chunked`로 보내는 경우가 많다. 이 경우 `Content-Length` 헤더 자체가 생략된다.

### 흐름 정리

```text
[클라이언트]                                    [서버]
    |                                            |
    |--- Accept-Encoding: gzip, deflate, br ---->|
    |                                            |  본문 gzip 압축
    |<--- Content-Encoding: gzip ----------------|
    |     (압축된 본문)                            |
```

서버가 압축을 지원하지 않거나, 응답이 이미 충분히 작아서 압축 효과가 없다고 판단하면 `Content-Encoding` 없이 원본을 보낸다. 클라이언트는 헤더 유무로 판단하므로 어느 쪽이든 문제없이 처리한다.

---

## 어떤 압축 방식을 쓸 것인가

`Accept-Encoding`에 들어갈 수 있는 방식은 여러 가지다.

| 방식        | 토큰      | 압축률                | 속도                     | 비고                                          |
| ----------- | --------- | --------------------- | ------------------------ | --------------------------------------------- |
| **gzip**    | `gzip`    | 보통                  | 보통                     | 사실상 표준. 모든 브라우저·서버 지원          |
| **deflate** | `deflate` | gzip과 유사           | gzip과 유사              | 스펙 모호성 때문에 사실상 사장됨              |
| **Brotli**  | `br`      | gzip 대비 15~25% 향상 | 압축은 느림, 해제는 비슷 | 브라우저는 HTTPS에서만 지원. 정적 자산에 적합 |
| **zstd**    | `zstd`    | Brotli급              | 압축·해제 모두 빠름      | RFC 8878. 2024년부터 브라우저 지원 시작       |

### deflate — 사장된 이유

Go 표준 라이브러리 `transport.go`의 주석이 핵심을 요약한다:

> _"Deflate is ambiguous and not as universally supported anyway."_

RFC 2616은 `deflate`를 "zlib 형식(RFC 1950)으로 감싼 deflate 압축 데이터"로 정의했다. 문제는 일부 서버가 raw deflate(RFC 1951)를 보내고, 일부는 zlib 래퍼를 포함해서 보낸다는 것이다. 클라이언트가 어떤 형식이 올지 예측할 수 없으니 호환성 문제가 생겼고, 결국 대부분의 구현체가 deflate를 피하고 gzip을 기본으로 채택했다.

### Brotli — 웹 콘텐츠에 최적화

Google이 개발했다. 웹에 최적화된 사전(dictionary)을 내장하고 있어서 HTML, CSS, JS에서 gzip보다 **15~25% 더 작은** 결과물을 만든다.

제약이 하나 있다: **브라우저는 HTTPS 연결에서만 `br`을 요청한다.** 이유는 두 가지다. HTTP 평문 연결에서는 중간 프록시가 `br`을 인식하지 못해 응답이 깨질 수 있고, 브라우저 벤더들이 강력한 신기능을 HTTPS에서만 활성화하는 정책("Encrypt the Web")을 밀고 있기 때문이다. curl 같은 비브라우저 클라이언트는 HTTP에서도 `br`을 사용할 수 있다.

압축 레벨이 높을수록 시간이 오래 걸리므로, 동적 응답보다는 **사전 압축(static compression)**에 적합하다.

### zstd — 속도와 압축률 모두

Facebook(Meta)이 개발했다. Brotli급 압축률에 압축·해제 속도가 훨씬 빠르다. 2024년부터 Chrome, Firefox가 지원을 시작했고 RFC 8878로 표준화되어 있다. 서버·CDN 지원은 아직 Brotli만큼 보편적이지 않지만 빠르게 확산 중이다.

### 현실적인 선택

- **범용 API 서버**: gzip이면 충분하다. 모든 클라이언트가 지원하고 설정이 간단하다.
- **정적 웹 자산**: Brotli 사전 압축이 최적이다. CDN에서 자동 처리된다.
- **고성능 내부 서비스**: zstd가 압축률 대비 속도에서 유리하다.
- **deflate**: 쓸 이유 없다.

---

## 클라이언트는 어떻게 처리하는가

백엔드 개발자가 HTTP 클라이언트로 다른 서비스를 호출할 때, 보통 gzip을 의식하지 않는다. 대부분의 클라이언트가 `Accept-Encoding` 설정과 응답 디코딩을 자동으로 처리하기 때문이다.

| 클라이언트                   | Accept-Encoding 자동 | 자동 디코딩 | 비고                                          |
| ---------------------------- | -------------------- | ----------- | --------------------------------------------- |
| **Go `net/http`**            | O                    | O           | `Transport.DisableCompression`으로 끌 수 있음 |
| **Python `requests`**        | O                    | O           | 헤더는 requests가, 디코딩은 urllib3가 처리    |
| **브라우저 `fetch`**         | O                    | O           | 항상 켜짐, 끌 수 없음                         |
| **Node.js `fetch` (undici)** | O                    | O           | v18부터 포함, v21에서 stable                  |
| **Node.js `http`**           | X                    | X           | 수동으로 `zlib.createGunzip()` 필요           |

"자동으로 처리한다"는 말은 내부에서 꽤 많은 일이 일어난다는 뜻이기도 하다. 각 클라이언트가 실제로 뭘 하는지 살펴보자.

### Go `net/http` — 조건부 자동 처리

Go의 HTTP Transport가 가장 흥미롭다. 무조건 gzip을 요청하는 게 아니라, **4가지 조건을 모두 만족할 때만** 자동으로 `Accept-Encoding: gzip`을 붙인다.

`transport.go`의 `roundTrip` 함수:

```go
requestedGzip := false
if !pc.t.DisableCompression &&
    req.Header.Get("Accept-Encoding") == "" &&
    req.Header.Get("Range") == "" &&
    req.Method != "HEAD" {
    requestedGzip = true
    req.extraHeaders().Set("Accept-Encoding", "gzip")
}
```

조건을 하나씩 보면:

1. **`DisableCompression`이 false** — 명시적으로 끄지 않았을 때
2. **사용자가 `Accept-Encoding`을 직접 설정하지 않음** — 직접 설정했다면 "내가 알아서 하겠다"는 의도
3. **`Range` 요청이 아님** — 압축된 문서의 바이트 범위를 지정하면 해제 시 엉뚱한 결과가 나온다
4. **`HEAD` 요청이 아님** — 일부 Nginx 버전의 버그를 우회하기 위함

deflate는 요청하지 않는다. 주석에 명시적으로 _"Deflate is ambiguous"_ 라고 적혀 있다.

응답을 받을 때는 `Content-Encoding: gzip`을 감지하면 **투명하게 디코딩**한다:

```go
if rc.addedGzip && ascii.EqualFold(resp.Header.Get("Content-Encoding"), "gzip") {
    resp.Body = &gzipReader{body: body}
    resp.Header.Del("Content-Encoding")
    resp.Header.Del("Content-Length")
    resp.ContentLength = -1
    resp.Uncompressed = true
}
```

여기서 일어나는 일:

- `resp.Body`를 `gzipReader`로 감싸서 읽을 때 자동으로 압축을 해제한다
- `Content-Encoding`과 `Content-Length` 헤더를 **삭제**한다 — 호출자에게는 압축이 없었던 것처럼 보인다
- `resp.Uncompressed = true`를 설정해서 자동 디코딩이 일어났는지 확인할 수 있게 한다

실제로 확인해보면:

```go
resp, _ := http.Get("https://google.com")
defer resp.Body.Close()

fmt.Println("Uncompressed:", resp.Uncompressed)                        // true
fmt.Println("Content-Encoding:", resp.Header.Get("Content-Encoding"))  // (빈 문자열)
```

`Uncompressed`가 `true`면 Transport가 gzip을 풀었다는 뜻이다. `Content-Encoding` 헤더는 이미 삭제되었으므로 빈 문자열이 나온다.

**수동 제어가 필요할 때**는 `Accept-Encoding`을 직접 설정하면 된다:

```go
req, _ := http.NewRequest("GET", "https://google.com", nil)
req.Header.Set("Accept-Encoding", "gzip")  // 직접 설정 → 자동 디코딩 비활성

resp, _ := http.DefaultClient.Do(req)
// resp.Body는 gzip 압축된 상태 → compress/gzip으로 직접 풀어야 함
```

이 설계의 핵심은, 사용자가 명시적으로 헤더를 설정했다면 "직접 다루겠다"는 의도로 간주한다는 것이다. 자동 기능이 사용자의 의도를 침범하지 않는다.

### Python requests — 역할 분담

requests와 urllib3는 역할을 나눈다. `Accept-Encoding` 헤더 설정은 **requests가 직접** 한다. `requests/utils.py`의 `default_headers()`에서 urllib3의 `make_headers(accept_encoding=True)`를 호출해 값을 생성하고, 이를 세션 기본 헤더에 넣는다. brotli 패키지가 설치되어 있으면 `gzip, deflate, br`이 되고, 없으면 `gzip, deflate`가 된다.

응답 디코딩은 **urllib3가 담당**한다. `response.py`의 `HTTPResponse`가 `Content-Encoding`을 보고 자동으로 압축을 풀어준다. `requests.get()`으로 받은 `response.text`는 이미 디코딩된 상태다.

### Node.js — 두 가지 세계

Node.js는 저수준 `http` 모듈과 고수준 `fetch` API의 동작이 다르다.

`fetch`(undici 기반)는 v18부터 core에 포함되었고, v21에서 stable로 승격되었다. 브라우저처럼 자동으로 `Accept-Encoding`을 설정하고 응답을 디코딩한다. 반면 `http` 모듈은 아무것도 자동으로 하지 않는다:

```js
const http = require("http");
const zlib = require("zlib");

http.get(url, { headers: { "Accept-Encoding": "gzip" } }, (res) => {
  const gunzip = zlib.createGunzip();
  res.pipe(gunzip);
  // gunzip에서 읽어야 압축 해제된 데이터를 얻는다
});
```

`http` 모듈을 직접 쓰는 경우 헤더 설정부터 디코딩까지 전부 수동이다.

---

## 서버 측: 누가 압축을 담당하는가

글 첫머리의 질문으로 돌아가자. 앱 서버 코드에 gzip 로직이 없는데 응답이 압축되어 있다면, **앱 서버 앞에 있는 무언가**가 처리하고 있는 것이다.

클라이언트가 `Accept-Encoding`을 보내도 **서버가 설정을 안 했으면 압축은 일어나지 않는다.** 그리고 대부분의 서버 프레임워크는 기본적으로 압축이 꺼져 있다.

| 서버                  | 기본값    | 설정 방법                                   |
| --------------------- | --------- | ------------------------------------------- |
| **Nginx**             | 꺼져 있음 | `gzip on;` (대부분의 기본 설정 파일에 포함) |
| **Express.js**        | 꺼져 있음 | `compression` 미들웨어 별도 추가            |
| **Go 내장 HTTP 서버** | 꺼져 있음 | 직접 구현하거나 미들웨어 필요               |

가장 흔한 구성인 Nginx를 예로 들면:

```nginx
gzip on;
gzip_types text/plain application/json application/javascript text/css;
gzip_min_length 1024;       # 1KB 미만은 압축 효과가 없으므로 건너뜀
gzip_proxied any;           # 프록시 뒤에서도 압축 적용
gzip_vary on;               # Vary: Accept-Encoding 헤더 추가
```

`gzip_vary on`이 추가하는 `Vary: Accept-Encoding` 헤더는 캐시 정합성에 중요하다. CDN이나 프록시가 같은 URL에 대해 압축된 버전과 비압축 버전을 구분해서 캐싱할 수 있게 해준다. 이 헤더가 없으면 gzip을 지원하지 않는 클라이언트에게 압축된 응답이 전달되는 캐시 오염이 발생할 수 있다.

이미 압축된 파일(JPEG, PNG, ZIP 등)이나 너무 작은 응답은 압축해도 효과가 없거나 오히려 커질 수 있다. `gzip_min_length`와 `gzip_types`로 대상을 적절히 제한해야 한다.

### 앱 서버가 아닌 앞단에서 처리하라

실무에서 권장되는 구조는 앱 서버가 아닌 **리버스 프록시나 CDN**에서 처리하는 것이다. 앱 서버는 비즈니스 로직에 집중하고, 압축 같은 전송 최적화는 앞단에 맡긴다.

```text
[클라이언트] → [CDN / LB / 리버스 프록시] → [앱 서버]
                     ↑ 여기서 압축
```

EKS 환경에서는 Istio의 Envoy 프록시가 gzip 압축을 담당할 수 있다. AWS ALB는 gzip 압축을 지원하지 않으므로, 서비스 메시 레이어에서 처리하는 구조가 된다.

---

## 확인하는 법

```bash
# --compressed: Accept-Encoding을 자동 설정하고 응답을 디코딩
# -v: 요청/응답 헤더를 모두 출력
curl --compressed -v https://your-api.com -o /dev/null 2>&1 | grep -i "content-encoding"
```

응답 헤더에 `Content-Encoding: gzip`(또는 `br`, `zstd`)이 있으면 압축이 적용된 것이다. 없으면 서버(또는 앞단 프록시) 설정을 확인해야 한다.

`curl -I`(HEAD 요청)로도 확인할 수 있지만, 일부 서버는 HEAD 요청에 `Content-Encoding`을 포함하지 않을 수 있으므로 GET 요청이 더 확실하다.
