---
title: "&가 사라졌다: URL, JSON, HTML 세 가지 인코딩 레이어 이해하기"
date: 2026-02-09 23:00:00 +0900
categories: [backend, web]
---

> Go 서버가 내려준 URL에서 query parameter가 통째로 사라지는 버그를 만났다. 원인을 추적하다 보니, 웹 개발에서 가장 헷갈리면서도 반드시 알아야 할 주제에 도달했다: **같은 문자 `&`를 세 가지 다른 방식으로 인코딩하는 세계.**

---

## 발단: 파라미터가 사라졌다

Go로 작성된 API 서버가 JSON 응답에 URL을 포함해서 내려주고 있었다. 대략 이런 형태다:

```json
{
  "click_tracker": "https://example.com/track?data=abc&position=3&session_id=xyz"
}
```

React 클라이언트가 이 URL을 받아서 그대로 호출하면 될 터였다. 그런데 서버에서 이런 에러가 돌아왔다:

```
"Query argument position is required, but not found"
```

`position=3`이 분명히 URL에 있는데 왜 없다고 하는 걸까?

---

## 단서: 실제 응답을 열어보다

`curl`로 API 응답의 raw bytes를 확인해봤다:

```json
{
  "click_tracker": "https://example.com/track?data=abc\u0026position=3\u0026session_id=xyz"
}
```

`&`가 `\u0026`으로 바뀌어 있었다. 이게 문제의 핵심이었다.

이 `\u0026`이 무엇이고, 왜 생기고, 왜 문제가 되는지 이해하려면 웹의 세 가지 인코딩 레이어를 알아야 한다.

---

## 레이어 1: URL Encoding (RFC 3986)

URL에는 특별한 의미를 가진 예약 문자들이 있다.

```
?   query string의 시작
&   파라미터 구분자
=   키-값 구분자
#   fragment 시작
/   경로 구분자
```

만약 이 문자들을 **데이터 값**으로 사용하고 싶으면, 있는 그대로 쓸 수 없다. `%XX` 형태로 인코딩해야 한다.

```
&  →  %26
=  →  %3D
?  →  %3F
```

예를 들어, `q` 파라미터에 "A&B"라는 값을 넣고 싶다면:

```
❌ ?q=A&B       → URL parser: q="A", B=""  (파라미터 2개로 해석)
✅ ?q=A%26B     → URL parser: q="A&B"      (파라미터 1개)
```

**`%26`은 URL parser만 이해한다.** 다른 레이어의 파서에게 넘기면 그냥 문자 3개(`%`, `2`, `6`)일 뿐이다.

---

## 레이어 2: JSON Encoding (RFC 8259)

JSON 문자열 안에서 유니코드 문자를 `\uXXXX` 형태로 표현할 수 있다. `XXXX`는 유니코드 코드포인트의 16진수 4자리다.

```
\u0026 = U+0026 = &
\u003c = U+003C = <
\u003e = U+003E = >
```

[RFC 8259](https://datatracker.ietf.org/doc/html/rfc8259)에 따르면:

- **반드시 이스케이프해야 하는 문자**: `"`, `\`, 제어 문자(U+0000~U+001F)
- **이스케이프할 수 있는 문자**: "Any character may be escaped"

즉, `&`를 `\u0026`으로 쓰는 것은 **허용이지 의무가 아니다.** 아래 두 JSON 문자열은 JSON 스펙상 완전히 동일하다:

```json
"A\u0026B"
"A&B"
```

JSON parser가 `\u0026`을 만나면 `&`로 디코딩한다. **`\u0026`은 JSON parser만 이해한다.** URL parser에게 넘기면 문자 6개(`\`, `u`, `0`, `0`, `2`, `6`)로 취급할 뿐이다.

---

## 레이어 3: HTML Encoding

HTML에서 `&`는 엔티티의 시작 문자다. 텍스트로 `&`를 표시하려면 `&amp;`로 이스케이프해야 한다.

```
&  →  &amp;
<  →  &lt;
>  →  &gt;
```

**`&amp;`는 HTML parser만 이해한다.**

---

## 핵심: 각 레이어의 파서는 자기 인코딩만 안다

같은 `&`를 표현하지만, **서로 다른 파서가 담당**한다:

| 인코딩 | `&`의 표현 | 디코딩 주체 |
|--------|-----------|------------|
| URL | `%26` | URL parser |
| JSON | `\u0026` | JSON parser |
| HTML | `&amp;` | HTML parser |

```
JSON의 \u0026 → URL parser에 넘기면? → 문자 6개로 취급 ❌
URL의  %26    → JSON parser에 넘기면? → 그냥 문자열 %26 ❌
HTML의 &amp;  → URL parser에 넘기면? → 그냥 문자열 &amp; ❌
```

**올바른 레이어의 파서를 반드시 거쳐야 한다.** 레이어를 건너뛰면 인코딩이 해석되지 않고 깨진다.

---

## 그러면 왜 Go는 `\u0026`을 만들었나

대부분의 언어에서 JSON 직렬화를 하면 `&`는 그대로 출력된다:

```python
# Python
json.dumps({"url": "a.com?x=1&y=2"})
# → {"url": "a.com?x=1&y=2"}
```

```javascript
// Node.js
JSON.stringify({url: "a.com?x=1&y=2"})
// → {"url":"a.com?x=1&y=2"}
```

하지만 **Go만 다르다:**

```go
// Go
json.Marshal(map[string]string{"url": "a.com?x=1&y=2"})
// → {"url":"a.com?x=1\u0026y=2"}
```

Go의 `json.Marshal()`은 기본적으로 `&`, `<`, `>`를 `\u0026`, `\u003c`, `\u003e`로 이스케이프한다.

이유는 역사적인 보안 문제 때문이다. 과거에 JSON을 HTML `<script>` 태그에 직접 삽입하는 패턴이 흔했다:

```html
<script>
  var config = {"redirect": "</script><script>alert('XSS')</script>"};
</script>
```

이 경우 JSON 안의 `</script>`를 브라우저 HTML 파서가 태그 종료로 해석하여 XSS 공격이 가능하다. Go 팀은 이런 상황을 방지하기 위해 기본값을 안전한 쪽으로 설정했다. [관련 이슈](https://github.com/golang/go/issues/56630)에서 많은 논쟁이 있었지만, Go 팀은 "Breaking change"를 이유로 기본 동작을 바꾸지 않았다.

JSON 스펙상 `\u0026`은 완전히 유효하다. 모든 정상적인 JSON 파서는 이를 올바르게 `&`로 디코딩한다. **서버는 잘못한 게 없다.**

---

## 돌아와서: 왜 파라미터가 사라졌는가

전체 흐름을 다시 보자.

### 정상 흐름

```
[서버] Go json.Marshal()
  URL: "...?data=abc&position=3"
         ↓ & → \u0026
  JSON: "...?data=abc\u0026position=3"

         ↓ HTTP 응답 전송

[클라이언트] response.json()  ← JSON parser 통과
  URL: "...?data=abc&position=3"
         ↓ \u0026 → &
  fetch(url)
         ↓

[서버] URL parser
  data="abc", position="3" ✅
```

### 문제 흐름

```
[서버] Go json.Marshal()
  JSON: "...?data=abc\u0026position=3"

         ↓ HTTP 응답 전송

[클라이언트] JSON parser를 거치지 않고 URL을 사용
  URL: "...?data=abc\u0026position=3"  ← \u0026이 그대로!
  fetch(url)
         ↓

[서버] URL parser
  \u0026은 URL 구분자(&)가 아님
  → data="abc\u0026position=3" (전부 data 값에 포함)
  → position 파라미터 없음 ❌
```

**JSON 레이어의 `\u0026`이 JSON parser를 거치지 않고 URL parser에 직접 전달되면서, `&`로 디코딩되지 않았다.** URL parser는 `\u0026`이 뭔지 모르니까, `position`은 별도의 파라미터가 아니라 `data` 값의 일부로 해석되었다.

---

## 교훈

1. **인코딩 레이어를 건너뛰지 마라.** JSON 응답에서 URL을 꺼낼 때는 반드시 JSON parser를 거쳐야 한다.
2. **Go의 `json.Marshal()`은 `&`를 `\u0026`으로 이스케이프한다.** 다른 언어에서는 보기 어려운 Go 고유의 동작이다.
3. **`\u0026`은 버그가 아니다.** JSON 스펙상 완전히 유효하다. 클라이언트가 JSON을 올바르게 파싱하면 문제없다.
4. **디버깅할 때 raw bytes를 확인하라.** `curl`로 API 응답의 원본을 보면, 눈에 보이지 않는 인코딩 차이를 발견할 수 있다.

---

## 부록: curl과 httpie는 왜 다르게 보이는가

이 버그를 디버깅할 때, 사용하는 HTTP 클라이언트에 따라 `\u0026`이 보이기도 하고 안 보이기도 한다. 이 차이를 모르면 디버깅 자체가 혼란스러워진다.

### curl: raw bytes를 있는 그대로 보여준다

```bash
$ curl -s https://api.example.com/ads | python3 -m json.tool
```

curl의 출력은 서버가 보낸 HTTP 응답 본문의 **원본 바이트 그 자체**다. Go 서버가 `\u0026`을 보냈으면, curl 출력에도 `\u0026`이 그대로 찍힌다.

```json
{"click_tracker": "https://example.com/track?data=abc\u0026position=3"}
```

> 주의: `python3 -m json.tool`로 파이프하면 Python의 JSON parser가 `\u0026`을 `&`로 디코딩해서 보여준다. raw bytes를 확인하려면 파이프 없이 `curl -s` 단독으로 써야 한다.

### httpie: 기본적으로 JSON을 파싱한 뒤 다시 직렬화한다

```bash
$ http https://api.example.com/ads
```

httpie의 기본 모드(`--pretty=all`)는 응답을 **JSON 파싱 → Python의 `json.dumps()`로 재직렬화 → 신택스 하이라이팅** 과정을 거친다. 이 과정에서 `\u0026`이 `&`로 디코딩된다.

```json
{
    "click_tracker": "https://example.com/track?data=abc&position=3"
}
```

`\u0026`이 사라졌다! 서버는 분명히 `\u0026`을 보냈는데, httpie가 중간에 JSON parser를 통과시켰기 때문이다.

### raw bytes를 보려면

```bash
# httpie에서 raw bytes 확인
$ http --pretty=none https://api.example.com/ads
```

`--pretty=none`으로 포맷팅을 끄면 curl과 동일하게 원본 바이트를 볼 수 있다.

### 정리

| 도구 | 동작 | `\u0026` 출력 |
|------|------|--------------|
| `curl` | raw bytes 그대로 | `\u0026` 보임 |
| `httpie` (기본) | JSON 파싱 후 재직렬화 | `&`로 변환됨 |
| `httpie --pretty=none` | raw bytes 그대로 | `\u0026` 보임 |

**디버깅할 때는 반드시 raw bytes를 확인하라.** httpie의 예쁜 출력을 믿으면 `\u0026` 문제를 영영 발견하지 못할 수 있다.

---

## 연습 문제

아래 상황들에서 어떤 일이 일어나는지 예측해보자.

### 문제 1

Go 서버가 다음 JSON을 반환한다:

```json
{"redirect": "https://shop.com/item?id=100\u0026category=food"}
```

JavaScript 클라이언트가 이렇게 처리한다:

```javascript
const res = await fetch('/api/data');
const text = await res.text();
const url = JSON.parse(text).redirect;
window.open(url);
```

`shop.com` 서버가 받는 query parameter는?

<details>
<summary>정답</summary>

`id=100`, `category=food`

`res.text()`로 받았지만, 그 다음에 `JSON.parse(text)`를 수행했으므로 `\u0026`이 `&`로 정상 디코딩된다. **JSON parser를 거쳤기 때문에 정상 동작한다.**

</details>

---

### 문제 2

Go 서버가 다음 JSON을 반환한다:

```json
{"redirect": "https://shop.com/search?q=A%26B\u0026page=2"}
```

JavaScript 클라이언트가 이렇게 처리한다:

```javascript
const data = await fetch('/api/data').then(r => r.json());
window.open(data.redirect);
```

`shop.com` 서버가 받는 query parameter는?

<details>
<summary>정답</summary>

`q=A&B`, `page=2`

단계별로 보면:
1. `r.json()`으로 JSON 파싱 → `\u0026`이 `&`로 디코딩
2. URL은 `https://shop.com/search?q=A%26B&page=2`
3. URL parser가 `&`를 파라미터 구분자로 인식 → `q`와 `page` 두 파라미터
4. URL parser가 `%26`을 디코딩 → `q`의 값은 `A&B`

두 가지 인코딩 레이어(JSON, URL)가 각각 자기 파서에 의해 순서대로 올바르게 처리된다.

</details>

---

### 문제 3

HTML 페이지에 다음 링크가 있다:

```html
<a href="https://example.com/search?q=hello&amp;lang=ko">검색</a>
```

사용자가 클릭하면 `example.com` 서버가 받는 query parameter는?

<details>
<summary>정답</summary>

`q=hello`, `lang=ko`

HTML parser가 `&amp;`를 `&`로 디코딩한 후 URL이 된다: `https://example.com/search?q=hello&lang=ko`. 그 다음 URL parser가 `&`를 파라미터 구분자로 인식한다.

만약 `&amp;` 대신 `&`를 그대로 썼다면? 결과는 같다. 하지만 HTML 스펙상 속성값 안의 `&`는 `&amp;`로 쓰는 것이 올바르다. 특히 `&lang`이 HTML 엔티티(`&lang;` = `⟨`)로 해석될 수 있는 경우 문제가 된다.

</details>

---

### 문제 4

Go 서버가 다음 URL을 `json.Marshal()`로 직렬화했다:

```
https://tracker.com/click?data=encrypted_payload%3D%3D&token=abc123
```

클라이언트가 받는 raw JSON bytes는?

<details>
<summary>정답</summary>

```json
"https://tracker.com/click?data=encrypted_payload%3D%3D\u0026token=abc123"
```

Go의 `json.Marshal()`은:
- `%3D`는 건드리지 않는다 (이건 일반 문자 `%`, `3`, `D`일 뿐)
- `&`만 `\u0026`으로 이스케이프한다 (HTML 안전성을 위한 Go 고유 동작)

`%3D%3D`는 URL encoding된 `==`이지만, JSON 직렬화 시점에서는 그냥 문자열이므로 추가 인코딩이 발생하지 않는다. **각 인코딩 레이어는 자기 레이어의 특수 문자만 처리한다.**

</details>

---

## 참고 자료

- [RFC 3986 - URI 문법](https://datatracker.ietf.org/doc/html/rfc3986) — URL/Percent Encoding 표준
- [RFC 8259 - JSON 데이터 교환 형식](https://datatracker.ietf.org/doc/html/rfc8259) — JSON 문자열 이스케이프 규칙
- [Go encoding/json 공식 문서](https://pkg.go.dev/encoding/json) — SetEscapeHTML 설명
- [Go issue #56630](https://github.com/golang/go/issues/56630) — escapeHTML 기본값 논쟁
- [Surprises and gotchas when working with JSON in Go](https://www.alexedwards.net/blog/json-surprises-and-gotchas)
