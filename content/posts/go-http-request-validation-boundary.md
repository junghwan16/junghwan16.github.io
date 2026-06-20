---
title: "Go HTTP 요청 검증은 어디까지 해야 할까"
url: "/backend/go/2026/06/20/go-http-request-validation-boundary/"
date: 2026-06-20 10:00:00 +0900
categories: [backend, go]
---

Go로 HTTP 서버를 만들다 보면 생각보다 빨리 이런 질문을 만난다.

"요청 검증은 어디서 해야 하지?"

핸들러에서 전부 해야 할까? 서비스 레이어로 넘겨야 할까? `go-playground/validator` 같은 라이브러리를 바로 붙여야 할까? 처음에는 작은 질문처럼 보이지만, 이 경계를 잘못 잡으면 HTTP 코드와 비즈니스 코드가 섞인다.

요즘 내가 잡고 있는 기준은 이렇다.

> HTTP handler는 요청이 애플리케이션으로 넘어갈 최소한의 모양을 갖췄는지만 확인한다.

---

## HTTP handler가 해야 하는 일

작은 Go 서버에서 `POST /orders` 같은 엔드포인트를 만든다고 해보자.

요청 body는 대략 이런 모양이다.

```json
{
  "customer_id": "cus_123",
  "items": [
    {
      "sku": "sku_abc",
      "quantity": 1
    }
  ]
}
```

이때 handler의 책임은 보통 여기까지다.

1. JSON body를 decode한다.
2. 모르는 필드를 허용할지 정한다.
3. 필수 필드가 비어 있는지 확인한다.
4. application command로 변환한다.
5. usecase를 호출한다.
6. 결과나 에러를 HTTP 응답으로 바꾼다.

코드로 쓰면 이런 느낌이다.

```go
type createOrderRequest struct {
	CustomerID string                   `json:"customer_id"`
	Items      []createOrderRequestItem `json:"items"`
}

type createOrderRequestItem struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

func (req createOrderRequest) valid() bool {
	if req.CustomerID == "" {
		return false
	}
	if len(req.Items) == 0 {
		return false
	}
	return true
}
```

그리고 handler에서는 decode와 validation을 분리해서 읽히게 한다.

```go
func (h *Handler) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&req); err != nil {
		writeAPIError(w, r, ErrInvalidRequest)
		return
	}

	if !req.valid() {
		writeAPIError(w, r, ErrInvalidRequest)
		return
	}

	cmd := req.toCommand()
	_ = cmd

	writeAPIError(w, r, ErrNotImplemented)
}
```

핸들러가 알아야 하는 것은 HTTP 요청의 모양이다. JSON field 이름, content type, body decode 실패, request id가 포함된 API error response 같은 것들이다.

반대로 주문이 실제로 생성 가능한지, 재고가 있는지, 고객이 주문 가능한 상태인지 같은 규칙은 handler가 알면 안 된다. 그건 application 또는 domain layer의 책임이다.

---

## DTO와 command는 분리한다

HTTP request DTO와 application command를 같은 타입으로 쓰면 처음에는 편하다.

하지만 시간이 지나면 HTTP의 사정이 애플리케이션 내부 타입으로 샌다. JSON field 이름, optional field 정책, 외부 API 호환성 같은 것들이 usecase 타입에 묻어난다.

그래서 handler에서 command로 변환하는 단계를 둔다.

```go
func (req createOrderRequest) toCommand() orders.CreateOrderCommand {
	items := make([]orders.CreateOrderItem, len(req.Items))
	for i, reqItem := range req.Items {
		items[i] = orders.CreateOrderItem{
			SKU:      reqItem.SKU,
			Quantity: reqItem.Quantity,
		}
	}

	return orders.CreateOrderCommand{
		CustomerID: req.CustomerID,
		Items:      items,
	}
}
```

`createOrderRequest`는 HTTP JSON shape다.

`orders.CreateOrderCommand`는 애플리케이션 usecase의 input이다.

둘은 지금은 거의 같아 보여도 역할이 다르다. 이 구분을 미리 해두면 나중에 HTTP API 버전이 바뀌거나, 내부 usecase가 바뀌어도 서로 덜 흔들린다.

---

## validation을 너무 깊게 파지 않는다

검증을 시작하면 끝이 없다.

- `customer_id`는 어떤 prefix를 가져야 하는가?
- `sku`는 어떤 문자만 허용하는가?
- `quantity`의 최대값은 얼마인가?
- 같은 sku가 여러 번 들어오면 합쳐야 하는가?
- 품절 상품이면 400인가, 409인가?

처음부터 이걸 다 handler에 넣기 시작하면 handler는 금방 비즈니스 로직 덩어리가 된다.

초기 HTTP 서버 구조를 잡는 단계라면 얕은 검증부터 두는 편이 낫다.

```text
malformed JSON -> 400 invalid_request
customer_id 없음 -> 400 invalid_request
items 비어 있음 -> 400 invalid_request
```

이 정도면 "HTTP 요청이 애플리케이션으로 넘어갈 최소한의 shape를 갖췄는가"는 확인할 수 있다.

더 깊은 규칙은 주문 usecase가 생긴 뒤에 다루는 편이 낫다.

---

## TDD에서 고정해야 하는 것

테스트를 먼저 쓰는 방식이라면 어떤 테스트를 써야 할지도 고민하게 된다.

테스트는 최종적으로 유지할 외부 동작을 고정해야 한다.

```go
func TestCreateOrder_InvalidJSON(t *testing.T)
func TestCreateOrder_MissingCustomerID(t *testing.T)
func TestCreateOrder_EmptyItems(t *testing.T)
```

이런 테스트는 괜찮다. 잘못된 요청이 `400 invalid_request`를 반환한다는 것은 실제 API contract이기 때문이다.

반대로 이런 테스트는 조심해야 한다.

```go
func TestCreateOrder_ValidRequestReturnsNotImplemented(t *testing.T)
```

`not_implemented`는 최종 요구사항이 아니라 개발 중 상태다. 이것을 테스트로 고정하면 "미완성 상태"가 API contract처럼 굳는다.

성공 경로 테스트는 실제로 원하는 성공 동작을 정한 뒤에 쓰는 편이 낫다.

```text
202 Accepted
또는
201 Created + order_id
```

---

## 작은 실수: make(len)과 append

DTO를 command로 바꿀 때 slice를 다루다가 이런 코드를 쓰곤 한다.

```go
items := make([]orders.CreateOrderItem, len(req.Items))
for _, reqItem := range req.Items {
	items = append(items, orders.CreateOrderItem{
		SKU:      reqItem.SKU,
		Quantity: reqItem.Quantity,
	})
}
```

이 코드는 겉보기엔 맞아 보이지만 틀렸다.

`make([]T, len(req.Items))`는 이미 길이가 `len(req.Items)`인 slice를 만든다. 그 뒤에 `append`하면 뒤에 새 요소가 추가된다. 앞쪽에는 zero-value item들이 남는다.

올바른 방식은 둘 중 하나다.

길이를 미리 잡고 index로 채우기:

```go
items := make([]orders.CreateOrderItem, len(req.Items))
for i, reqItem := range req.Items {
	items[i] = orders.CreateOrderItem{
		SKU:      reqItem.SKU,
		Quantity: reqItem.Quantity,
	}
}
```

또는 capacity만 잡고 append하기:

```go
items := make([]orders.CreateOrderItem, 0, len(req.Items))
for _, reqItem := range req.Items {
	items = append(items, orders.CreateOrderItem{
		SKU:      reqItem.SKU,
		Quantity: reqItem.Quantity,
	})
}
```

둘 다 괜찮다. 길이를 잡았다면 index로 채우고, append를 쓰고 싶다면 길이는 0으로 두면 된다.

---

## 내가 두는 경계

Go HTTP handler에서 request validation은 너무 거창하게 시작하지 않아도 된다.

- handler는 HTTP DTO를 decode한다.
- 얕은 request shape validation만 한다.
- DTO를 application command로 변환한다.
- 비즈니스 규칙은 usecase/domain layer로 넘긴다.
- 테스트는 최종 API contract만 고정한다.

이 정도 경계만 지켜도 HTTP 서버 구조가 덜 엉킨다. validation을 얼마나 많이 하느냐보다, 어떤 책임을 어느 레이어에 둘지 계속 같은 기준으로 유지하는 쪽이 더 어렵다.
