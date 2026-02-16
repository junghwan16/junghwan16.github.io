---
layout: single
title: "AWS S3에서 9 세어 보기 — 가용성과 내구성의 차이"
date: 2026-02-16 13:00:00 +0900
categories: [backend, infrastructure]
---

AWS S3 Standard의 스펙을 보면 두 가지 숫자가 눈에 띈다.

| 항목 | 수치 | 9의 개수 |
|---|---|---|
| 가용성(Availability) | 99.99% | 4개 |
| 내구성(Durability) | 99.999999999% | **11개** |

가용성 Four 9s(99.99%)는 1년에 약 52분 정도 접근이 안 될 수 있다는 뜻이다. 반면 내구성 Eleven 9s(99.999999999%)는 객체 10,000개를 저장하면 평균적으로 **1,000만 년에 1개**를 잃을 수 있다는 뜻이다.

가용성과 내구성은 다른 개념이다.

- **가용성**: 지금 접근할 수 있는가? (일시적 장애)
- **내구성**: 데이터가 사라지지 않는가? (영구적 손실)

S3에 잠깐 접속이 안 될 수는 있어도(가용성), 저장한 파일이 증발할 확률은 거의 없다(내구성).

---

## 참고자료

- [Amazon S3 Storage Classes](https://aws.amazon.com/s3/storage-classes/) — S3 스토리지 클래스별 가용성·내구성 스펙
- [Amazon S3 FAQs](https://aws.amazon.com/s3/faqs/) — S3 내구성 11 Nines에 대한 공식 설명
