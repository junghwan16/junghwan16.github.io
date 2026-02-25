---
title: "유닛 테스트에서 '무엇을' 테스트해야 하는가"
date: 2026-02-08 12:00:00 +0900
categories: [backend, testing]
---

> Martin Fowler 블로그에 게시된 Ham Vocke의 [The Practical Test Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html) 중 "What to Test?" 섹션을 읽고, 얻은 교훈을 Go 예제와 함께 정리했다.

---

## 교훈 1. "어떻게"가 아니라 "무엇을" 테스트하라

주문 가격을 계산하는 함수가 있다고 하자.

```go
func (p *PriceCalculator) FinalPrice(basePrice float64, level string) float64 {
    discounted := p.discounter.Apply(basePrice, level)
    return p.taxCalc.AddTax(discounted)
}
```

나쁜 테스트는 내부 호출을 검증한다:

```go
// ❌ "Discounter.Apply가 1번 호출되었는가?"
// ❌ "TaxCalculator.AddTax에 9000이 전달되었는가?"
```

이러면 내부 구조를 리팩터링하는 순간 테스트가 전부 깨진다. 동작은 그대로인데.

좋은 테스트는 입력과 출력만 본다:

```go
// ✅
func TestFinalPrice(t *testing.T) {
    calc := NewPriceCalculator(NewTaxCalculator(0.1), NewDiscounter(0.1))

    got := calc.FinalPrice(10000, "gold")

    if got != 9900 { // 10000 * 0.9 * 1.1
        t.Errorf("FinalPrice() = %v, want 9900", got)
    }
}
```

내부에서 `Apply`를 호출하든 `Rate`를 가져와서 직접 계산하든 상관없다. **리팩터링해도 이 테스트는 살아남는다.** 그게 안전망이다.

---

## 교훈 2. private 메서드를 테스트하고 싶으면 설계를 의심하라

Go에서 unexported 메서드는 같은 패키지에서 접근할 수 있으니 테스트할 수는 있다. 하지만 그러고 싶다는 충동 자체가 신호다.

```go
func (s *SalesReport) Generate() Summary {
    total := s.calculateTotal()      // unexported
    avg := s.calculateAverage(total) // unexported
    return Summary{Total: total, Average: avg}
}
```

`calculateTotal`을 직접 테스트하지 말고, `Generate()`의 결과로 검증하면 된다. 만약 unexported 로직이 너무 복잡해서 독립적으로 테스트하고 싶다면, 그건 별도 타입으로 분리해야 한다는 뜻이다.

```go
// 분리 전: 100줄짜리 로직이 private에 묻혀 있음
func (s *SalesReport) findTopProducts() []string { /* ... */ }

// 분리 후: public 인터페이스가 생기니 당당하게 테스트 가능
type ProductRanker struct{}
func (r *ProductRanker) Rank(orders []Order) []string { /* ... */ }
```

---

## 교훈 3. 사소한 코드는 테스트하지 마라

Kent Beck도 괜찮다고 했다.

```go
// ❌ 이걸 왜 테스트하나
func TestNewUser(t *testing.T) {
    u := NewUser("홍길동", "hong@test.com", 30)
    if u.Name != "홍길동" { t.Error("...") }  // struct 대입이 실패할 리가 없다
}
```

분기가 없는 코드는 깨질 일이 없다. 하지만 검증 로직이 있으면 다르다:

```go
// ✅ 분기가 있으니 테스트할 가치가 있다
func NewUser(name, email string, age int) (*User, error) {
    if name == "" {
        return nil, errors.New("이름은 필수이다")
    }
    if age < 0 || age > 200 {
        return nil, errors.New("나이가 유효하지 않다")
    }
    return &User{Name: name, Email: email, Age: age}, nil
}
```

기준은 단순하다: **if문이 있으면 테스트하고, 없으면 넘어가라.**

---

## 정리

```
"이 코드를 테스트해야 하나?"
        │
        ├── 분기가 있는가?
        │       ├── 없다 → 넘어가라
        │       └── 있다 → 테스트하라
        │
        ├── public인가?
        │       ├── 그렇다 → 테스트하라
        │       └── private이다 → Generate() 같은 public 메서드를 통해 검증하라
        │
        └── "입력 X → 출력 Y"를 검증하는가?
                ├── 그렇다 → ✅ 좋은 테스트
                └── "A를 호출하고 B를 호출하고..." → ❌ 리팩터링하면 깨진다
```

100% 커버리지는 목표가 아니다. getter 테스트를 하나 빼고 경계값 테스트를 하나 더 추가하는 게 낫다.

---

## 참고자료

- [Martin Fowler - The Practical Test Pyramid (Ham Vocke)](https://martinfowler.com/articles/practical-test-pyramid.html) — 이 글의 원문
- [Kent Beck - Programmer Test Principles](https://tidyfirst.substack.com/p/programmer-test-principles) — "사소한 코드는 테스트하지 마라"의 원전
- [Go Wiki - Table Driven Tests](https://go.dev/wiki/TableDrivenTests) — Go에서 테이블 기반 테스트를 작성하는 관례
