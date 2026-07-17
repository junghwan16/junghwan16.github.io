---
title: "&가 사라졌다"
url: "/backend/web/2026/02/09/encoding-layers-url-json-html/"
date: 2026-02-09 23:00:00 +0900
categories: [backend, web]
---

Go 서버가 JSON 응답에 URL을 담아 내려줬다. URL에는 `&position=3`이 있었는데, 클라이언트에서 호출하니 서버는 `position` 파라미터가 없다고 했다.

응답을 raw로 보니 이런 모양이었다.

```json
{
  "click_tracker": "https://example.com/track?data=abc\u0026position=3"
}
```

`&`가 `\u0026`으로 바뀌어 있었다. 문제는 Go가 `&`를 이렇게 쓴 것이 아니라, 이 문자열을 올바른 레이어의 파서로 통과시키지 않은 데 있었다.

## 세 가지 `&`

같은 문자라도 어느 문법 안에 있느냐에 따라 표현 방식이 다르다.

| 레이어 | `&` 표현 | 해석하는 파서 |
|---|---|---|
| URL | `%26` | URL parser |
| JSON | `\u0026` | JSON parser |
| HTML | `&amp;` | HTML parser |

각 인코딩은 자기 레이어에서만 의미가 있다. URL parser는 `\u0026`을 `&`로 바꾸지 않는다. JSON parser는 `%26`을 디코딩하지 않는다. HTML parser만 `&amp;`를 `&`로 본다.

## URL에서 `&`는 구분자다

URL query string에서 `&`는 파라미터를 나누는 문자다.

```text
?data=abc&position=3
```

여기서는 `data=abc`, `position=3`이라는 두 파라미터가 된다. 반대로 값 안에 `&`를 넣고 싶다면 `%26`으로 URL 인코딩해야 한다.

```text
?q=A%26B
```

URL parser를 통과한 뒤에야 `q` 값은 `A&B`가 된다.

## JSON에서 `\u0026`은 유효한 문자열 표현이다

JSON 문자열 안에서는 유니코드 문자를 `\uXXXX`로 쓸 수 있다.

```json
"A\u0026B"
"A&B"
```

두 값은 JSON 관점에서 같다. JSON parser를 통과하면 둘 다 `A&B`가 된다.

Go의 `encoding/json`은 기본적으로 `<`, `>`, `&`를 유니코드 escape로 출력한다. 과거에 JSON을 HTML `<script>` 안에 직접 넣던 패턴에서 XSS 위험을 줄이기 위한 기본값이다. 그래서 Go 서버가 `\u0026`을 보냈다는 사실만으로는 버그가 아니다.

## 문제가 되는 흐름

정상 흐름은 이렇다.

```text
Go json.Marshal
  "...?data=abc\u0026position=3"
        |
        v
클라이언트 JSON parser
  "...?data=abc&position=3"
        |
        v
fetch(url)
```

문제 흐름은 JSON parser를 건너뛸 때 생긴다.

```text
raw response text
  "...?data=abc\u0026position=3"
        |
        v
그대로 URL로 사용
        |
        v
URL parser는 \u0026을 구분자로 보지 않음
```

그 결과 query는 `data=abc\u0026position=3` 하나로 해석되고, `position` 파라미터는 존재하지 않게 된다.

## 고치는 법

클라이언트가 JSON 응답을 받았다면 반드시 JSON parser를 통과시킨 뒤 필드를 꺼낸다.

```js
const res = await fetch("/api");
const body = await res.json();
await fetch(body.click_tracker);
```

디버깅 때문에 raw text를 직접 만질 때도, 그 문자열이 어느 레이어의 문법인지 먼저 확인해야 한다.

```js
const text = await res.text();
const body = JSON.parse(text);
await fetch(body.click_tracker);
```

Go에서 꼭 `&`를 그대로 출력해야 한다면 encoder의 HTML escaping을 끌 수 있다.

```go
enc := json.NewEncoder(w)
enc.SetEscapeHTML(false)
enc.Encode(resp)
```

다만 이건 출력 모양을 바꾸는 선택이지, 정상 JSON parser를 거쳐야 한다는 원칙을 대신하지 않는다.

## 남는 규칙

- URL 값 안의 예약 문자는 URL 인코딩한다.
- JSON 문자열 안의 `\u0026`은 JSON parser가 풀어야 한다.
- HTML 안의 `&amp;`는 HTML parser가 풀어야 한다.
- raw bytes에서 보이는 표현과 애플리케이션이 쓰는 문자열을 구분한다.
- 한 레이어의 escape를 다른 레이어의 parser에게 기대하지 않는다.

`&`가 사라진 것이 아니라, 아직 JSON 문자열 안에 있었다. 올바른 파서를 한 번 거치면 다시 URL의 `&`가 된다.
