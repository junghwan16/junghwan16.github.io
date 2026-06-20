---
title: "Go 의존성은 인터페이스로 받고 구현체는 포인터로 만든다"
url: "/backend/go/2026/06/20/go-dependency-injection-value-pointer/"
date: 2026-06-20 10:10:00 +0900
categories: [backend, go]
---

Go에서 의존성 주입을 하다 보면 이런 고민을 자주 한다.

```go
func NewHandler(service Service) *Handler
```

이렇게 값으로 받을까?

```go
func NewHandler(service *Service) *Handler
```

이렇게 포인터로 받을까?

인터페이스라면?

```go
func NewHandler(service ServiceInterface) *Handler
```

아니면 혹시 인터페이스 포인터?

```go
func NewHandler(service *ServiceInterface) *Handler
```

처음에는 다 비슷해 보인다. 하지만 Go에서는 꽤 일관된 기준이 있다.

---

## 인터페이스는 value로 받는다

HTTP handler가 주문 생성 usecase에 의존한다고 해보자.

```go
type orderCreator interface {
	CreateOrder(ctx context.Context, cmd orders.CreateOrderCommand) (orders.CreateOrderResult, error)
}

type Handler struct {
	orderCreator orderCreator
}

func NewHandler(orderCreator orderCreator) *Handler {
	return &Handler{orderCreator: orderCreator}
}
```

여기서 `orderCreator`는 인터페이스다. 인터페이스는 value로 받는 게 일반적이다.

인터페이스 값은 내부적으로 "구체 타입 + 구체 값"을 들고 있다. 그래서 인터페이스 자체를 다시 포인터로 감쌀 필요가 거의 없다.

이런 형태는 피하는 편이 좋다.

```go
type Handler struct {
	orderCreator *orderCreator
}
```

왜냐하면 `orderCreator`가 인터페이스가 아니라 "인터페이스를 가리키는 포인터"가 되기 때문이다. 메서드 호출도 어색해진다.

```go
func (h *Handler) Serve(ctx context.Context, cmd orders.CreateOrderCommand) error {
	_, err := (*h.orderCreator).CreateOrder(ctx, cmd)
	return err
}
```

반면 인터페이스 값을 필드로 두면 호출 형태가 바로 드러난다.

```go
func (h *Handler) Serve(ctx context.Context, cmd orders.CreateOrderCommand) error {
	_, err := h.orderCreator.CreateOrder(ctx, cmd)
	return err
}
```

그래서 나는 이렇게 둔다.

```text
인터페이스는 value로 받는다.
인터페이스 포인터는 거의 쓰지 않는다.
```

---

## concrete 구현체는 보통 pointer로 만든다

생성자는 인터페이스를 받지만, 실제로 넘기는 구현체는 포인터인 경우가 많다.

```go
creator := &orders.OrderCreator{}
handler := api.NewHandler(creator)
```

`NewHandler`는 `orderCreator` 인터페이스를 받는다. `&orders.OrderCreator{}`는 그 인터페이스를 만족하는 concrete 구현체다.

구현체를 pointer로 넘기는 이유는 보통 세 가지다.

첫째, 상태를 공유해야 한다.

DB pool, repository, HTTP client, logger 같은 것들은 요청마다 복사해서 쓰는 데이터가 아니다. 애플리케이션 전체에서 공유되는 리소스에 가깝다.

둘째, 메서드 receiver가 pointer인 경우가 많다.

```go
func (o *OrderCreator) CreateOrder(ctx context.Context, cmd CreateOrderCommand) (CreateOrderResult, error) {
	// ...
}
```

이렇게 메서드를 정의하면 `*OrderCreator`가 인터페이스를 만족한다. `OrderCreator` 값은 이 메서드 집합을 만족하지 않을 수 있다.

셋째, 큰 struct 복사를 피한다.

service struct가 repository, logger, client, cache 등을 들고 있다면 값 복사는 의미가 없거나 위험하다.

---

## 값으로 넘겨도 되는 것들

그렇다고 Go에서 모든 것을 포인터로 넘기는 건 아니다.

요청 하나를 표현하는 command는 보통 value로 넘겨도 괜찮다.

```go
type CreateOrderCommand struct {
	CustomerID string
	Items      []CreateOrderItem
}
```

이건 "요청 시점의 데이터"다. 복사해도 의미가 유지된다.

결과 타입도 마찬가지다.

```go
type CreateOrderResult struct {
	OrderID string
	Status  string
}
```

작은 read-only config도 value로 넘겨도 괜찮다.

```go
type ServerConfig struct {
	Addr         string
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
}
```

기준은 이것이다.

```text
이 값이 상태 없는 데이터인가?
아니면 공유 리소스나 내부 상태를 가진 객체인가?
```

상태 없는 데이터면 value로 넘긴다.

공유 리소스나 내부 상태가 있으면 pointer로 넘긴다.

---

## mutex가 있는 struct를 복사하면 왜 위험할까

repository가 내부 cache와 mutex를 가진다고 해보자.

```go
type OrderRepository struct {
	mu    sync.Mutex
	cache map[string]Order
}
```

이 값을 복사하면 어떤 일이 생길까?

```go
repo2 := repo1
```

struct value copy는 필드들을 복사한다. `sync.Mutex`도 struct 값이기 때문에 복사된다.

```text
repo1.mu  // mutex A
repo2.mu  // mutex B
```

반면 map은 header가 복사되고 underlying map은 공유된다.

```text
repo1.cache ─┐
             ├── same underlying map
repo2.cache ─┘
```

이제 문제가 생긴다.

```go
go repo1.Set("a", orderA) // repo1.mu lock
go repo2.Set("b", orderB) // repo2.mu lock
```

두 goroutine은 서로 다른 mutex를 잠근다. 하지만 실제로 쓰는 map은 같다.

겉으로는 lock을 쓰고 있지만, 같은 공유 자원을 같은 lock으로 보호하지 못한다. 결과적으로 data race나 `concurrent map writes`가 날 수 있다.

그래서 mutex를 가진 struct는 사용 후 복사하지 않는 것이 기본이다. 이런 객체는 pointer 하나를 공유하는 편이 안전하다.

```go
repo := &OrderRepository{
	cache: map[string]Order{},
}

creator := &OrderCreator{
	repo: repo,
}
```

---

## DB pool도 같은 기준으로 본다

`*sql.DB`는 단일 DB 연결이 아니다. connection pool handle이다.

내부에는 idle connection, open connection 수, wait queue, mutex 같은 상태가 있다. 그래서 보통 repository는 `*sql.DB`를 들고 간다.

```go
type PostgresOrderRepository struct {
	db *sql.DB
}
```

이런 식으로 DB pool 객체 자체를 복사하는 형태는 피해야 한다.

```go
func NewRepo(db *sql.DB) PostgresOrderRepository {
	return PostgresOrderRepository{
		db: *db, // 좋지 않음
	}
}
```

pool의 내부 상태와 lifecycle이 불분명해진다. 어떤 copy를 닫았는지, 어떤 pool state가 진짜인지, 동기화가 안전한지 판단하기 어렵다.

---

## 기준표

내가 기억하려는 규칙은 이렇다.

```text
interface dependency field  -> interface value
concrete service/repository -> pointer
command/result/DTO          -> value
DB pool/client/logger       -> pointer
small read-only config      -> value도 가능
```

Go에서 의존성 주입은 프레임워크보다 타입 선택에서 갈린다.

인터페이스는 소비하는 쪽에서 작게 정의하고 value로 받는다. 실제 구현체는 보통 pointer로 만들고, 상태 없는 데이터는 value로 넘긴다. 이 정도만 지켜도 handler, service, repository 사이의 경계가 덜 흐려진다.
