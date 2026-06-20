---
title: "http.HandlerFunc는 함수에 메서드를 붙인 타입이다"
url: "/backend/go/2026/05/23/go-handler-func/"
date: 2026-05-23 10:00:00 +0900
categories: [backend, go]
---

Go로 HTTP 서버를 처음 짤 때 이런 코드를 본다.

```go
http.ListenAndServe(":8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("hello"))
}))
```

`http.HandlerFunc(...)`가 왜 필요하지? 그냥 함수를 넘기면 안 되나? `ListenAndServe`의 시그니처를 보면 두 번째 인자는 `http.Handler` 인터페이스다. 함수를 인터페이스 자리에 넣는데 컴파일이 된다. 캐스팅 같기도 하고, 생성자 호출 같기도 하다.

답은 둘 다 아니다. Go의 **함수 타입(named function type)**과 **메서드**가 만나면 함수도 인터페이스를 만족할 수 있다.

---

## 함수 타입은 그냥 타입이다

Go에서는 함수 시그니처에도 이름을 붙일 수 있다.

```go
type HandlerFunc func(ResponseWriter, *Request)
```

`HandlerFunc`는 "이런 시그니처를 가진 함수"라는 타입이다. `int`나 `string`처럼 평범한 타입이고, 변수에 담을 수도 있다.

```go
var f HandlerFunc = func(w ResponseWriter, r *Request) {
    w.Write([]byte("hi"))
}
f(w, r)  // 그냥 호출 가능
```

여기까지는 타입 별칭처럼 보인다. 하지만 함수 타입에 **메서드**를 붙일 수 있다는 점이 결정적이다.

---

## 함수 타입에 메서드를 붙인다

`net/http` 패키지의 실제 정의는 이렇다.

```go
type HandlerFunc func(ResponseWriter, *Request)

func (h HandlerFunc) ServeHTTP(w ResponseWriter, r *Request) {
    h(w, r)
}
```

`HandlerFunc` 타입에 `ServeHTTP` 메서드가 달려 있다. 메서드 본문은 자기 자신(`h`)을 함수로 호출하는 것뿐이다.

그리고 `http.Handler` 인터페이스는 이렇게 생겼다.

```go
type Handler interface {
    ServeHTTP(ResponseWriter, *Request)
}
```

`HandlerFunc`는 `ServeHTTP` 메서드를 가지므로 `Handler` 인터페이스를 만족한다. 함수 본문은 그대로지만, 이름 붙은 타입이 되면서 메서드 집합이 생긴다.

---

## 그래서 `http.HandlerFunc(...)`는 뭘 하는가

```go
http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("hello"))
})
```

이건 함수 호출이 아니라 **타입 변환**이다. `int(3.14)`가 float을 int로 변환하듯, 익명 함수를 `HandlerFunc` 타입으로 변환한다.

변환 전: 그냥 `func(ResponseWriter, *Request)` 타입의 함수. 메서드 없음. `Handler` 인터페이스 만족 안 함.

변환 후: `HandlerFunc` 타입. `ServeHTTP` 메서드 있음. `Handler` 인터페이스 만족.

같은 함수 본문이지만 타입이 다르고, 타입이 다르니 붙어있는 메서드 집합도 다르다.

```go
fn := func(w http.ResponseWriter, r *http.Request) { /* ... */ }

var h1 http.Handler = fn                    // 컴파일 에러
var h2 http.Handler = http.HandlerFunc(fn)  // OK
```

`http.ListenAndServe(":8080", fn)`이 안 되고 `http.ListenAndServe(":8080", http.HandlerFunc(fn))`이 되는 이유다.

---

## 왜 이렇게 설계했을까

`Handler` 인터페이스만 있었다면 매번 구조체를 만들어야 한다.

```go
type helloHandler struct{}

func (helloHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("hello"))
}

http.ListenAndServe(":8080", helloHandler{})
```

상태가 없는 핸들러에 구조체를 매번 정의하는 건 번거롭다. `HandlerFunc`는 이 보일러플레이트를 없애는 어댑터다.

- 상태가 필요 없으면 함수를 `HandlerFunc`로 감싸 쓴다.
- 상태나 의존성(DB, 로거 등)이 필요하면 구조체에 `ServeHTTP`를 구현한다.

같은 인터페이스를 두 가지 스타일로 만족시킬 수 있다.

---

## `http.HandleFunc`와 헷갈리지 말기

비슷한 이름이 셋이다.

| 이름 | 무엇 |
|---|---|
| `http.Handler` | 인터페이스 — `ServeHTTP` 메서드 요구 |
| `http.HandlerFunc` | 함수 타입 — `ServeHTTP` 메서드 갖고 있어 `Handler` 만족 |
| `http.HandleFunc` | 함수 — `DefaultServeMux`에 라우트 등록 |

`HandleFunc`(동사)는 라우트를 등록하는 함수다. 내부적으로 인자를 `HandlerFunc`로 변환해서 mux에 넣는다.

```go
// 함수로 라우트 등록
http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("hello"))
})

// 위 호출이 내부에서 하는 일과 거의 동일
http.DefaultServeMux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("hello"))
}))
```

`Handle`은 `Handler`를 받고, `HandleFunc`는 함수를 받아서 내부적으로 `HandlerFunc`로 감싼다. 이름이 비슷한 건 우연이 아니다 — 둘은 짝이다.

---

## 미들웨어가 자연스러워진다

`Handler`가 인터페이스고 `HandlerFunc`가 어댑터라는 점 덕분에 미들웨어 패턴이 매끄럽게 굴러간다.

```go
func logging(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        next.ServeHTTP(w, r)
        slog.Info("request", "path", r.URL.Path, "dur", time.Since(start))
    })
}
```

- 들어오는 건 `Handler` — 함수든 구조체든 상관없이 감쌀 수 있다.
- 나가는 것도 `Handler` — 다시 다른 미들웨어로 감쌀 수 있다.
- 내부 구현은 `HandlerFunc`로 익명 함수를 감싸 만든다.

```go
mux := http.NewServeMux()
mux.HandleFunc("/", helloHandler)

http.ListenAndServe(":8080", logging(auth(mux)))
```

`mux`도 `Handler`, `auth(mux)`도 `Handler`, `logging(...)`도 `Handler`. 같은 인터페이스에 다 맞물려서 합성된다.

---

## 같은 패턴은 표준 라이브러리 곳곳에 있다

`HandlerFunc`만의 특별한 트릭이 아니다. Go 표준 라이브러리는 "함수 타입 + 메서드 = 인터페이스 어댑터" 패턴을 여러 곳에서 쓴다.

```go
// sort.Slice — sort.Interface를 함수로 만족시킨다
type lessFunc func(i, j int) bool

// http.FileSystem 어댑터
type Dir string
func (d Dir) Open(name string) (File, error) { /* ... */ }
```

`net/http`에서는 `HandlerFunc`가 대표 사례지만, 같은 방식은 다른 단일 메서드 인터페이스에도 적용된다. 함수 타입에 필요한 메서드를 붙이면 된다.

---

## 다시 처음 코드로

처음 봤던 코드를 다시 보자.

```go
http.ListenAndServe(":8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("hello"))
}))
```

이제 한 줄씩 읽힌다.

1. 익명 함수를 만든다 — 타입은 `func(ResponseWriter, *Request)`.
2. `http.HandlerFunc(...)`로 타입 변환한다 — 이제 `ServeHTTP` 메서드가 붙어 `Handler` 인터페이스를 만족한다.
3. `ListenAndServe`에 `Handler`로 넘긴다.

여기서 쓰인 규칙은 세 가지다.

- 함수 시그니처에도 이름(타입)을 붙일 수 있다.
- 그 타입에 메서드를 붙일 수 있다.
- 메서드가 인터페이스 요건을 충족하면, 그 함수는 인터페이스가 된다.

Go의 타입 시스템이 가진 작은 규칙 몇 개를 조합하면 "함수를 인터페이스 자리에 끼우는" 일이 특별한 문법 없이 설명된다. 한 번 분해해서 보면 타입과 메서드의 조합일 뿐이다.
