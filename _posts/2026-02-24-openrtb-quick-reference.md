---
layout: single
title: "OpenRTB 2.6 Quick Reference Card"
date: 2026-02-24 13:00:00 +0900
categories: [ad-tech, openrtb]
---

## HTTP 규약 한눈에 보기

| 항목 | 값 |
|------|-----|
| Method | POST |
| Request Content-Type | `application/json` |
| Response Content-Type | `application/json` |
| 압축 (요청) | `Content-Encoding: gzip` |
| 압축 (응답) | `Accept-Encoding: gzip` |
| No-Bid HTTP | `204 No Content` (body 없음) |
| 낙찰 HTTP | `200 OK` + BidResponse body |
| 타임아웃 초과 | DSP 측 무응답 → SSP가 no-bid 처리 |
| OpenRTB 버전 헤더 | `x-openrtb-version: 2.6` |

---

## BidRequest 필수/권장 필드 체크표

### BidRequest (최상위)

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `id` | string | 필수 |
| `imp` | array of Imp | 필수 |
| `site` / `app` | object | 권장 |
| `device` | object | 권장 |
| `user` | object | 권장 |
| `tmax` | integer (ms) | 권장 |
| `cur` | array of string | 권장 |
| `at` | integer (1=1st, 2=2nd) | 권장 |

### Imp

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `id` | string | 필수 |
| `banner` / `video` / `native` | object | 필수(택1) |
| `bidfloor` | float | 권장 |
| `bidfloorcur` | string | 권장 |
| `secure` | integer (0/1) | 권장 |

### Banner

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `w` | integer | 권장 |
| `h` | integer | 권장 |
| `format` | array of Format | 권장 |
| `btype` | array of integer | 권장 |
| `pos` | integer | 권장 |

### Video

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `mimes` | array of string | 필수 |
| `minduration` | integer | 권장 |
| `maxduration` | integer | 권장 |
| `protocols` | array of integer | 권장 |
| `plcmt` | integer | 권장 |
| `playbackmethod` | array of integer | 권장 |
| `w` / `h` | integer | 권장 |

### Site / App

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `id` | string | 권장 |
| `page` (Site) / `bundle` (App) | string | 권장 |
| `domain` (Site) / `storeurl` (App) | string | 권장 |
| `publisher` | object | 권장 |
| `cat` | array of string | 권장 |

### Device

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `ua` | string | 권장 |
| `ip` | string | 권장 |
| `devicetype` | integer | 권장 |
| `make` / `model` / `os` | string | 권장 |
| `language` | string | 권장 |
| `connectiontype` | integer | 권장 |

### User

| 필드 | 타입 | 필수/권장 |
|------|------|-----------|
| `id` | string | 권장 |
| `buyeruid` | string | 권장 |
| `data` | array of Data | 선택 |

---

## BidResponse 필수 필드 체크표

| 객체 | 필드 | 타입 | 필수/권장 |
|------|------|------|-----------|
| BidResponse | `id` | string | 필수 (BidRequest.id 에코) |
| BidResponse | `seatbid` | array of SeatBid | 필수 |
| BidResponse | `cur` | string | 권장 |
| SeatBid | `bid` | array of Bid | 필수 |
| SeatBid | `seat` | string | 권장 |
| Bid | `id` | string | 필수 |
| Bid | `impid` | string | 필수 (Imp.id 에코) |
| Bid | `price` | float | 필수 |
| Bid | `adm` | string | 권장 |
| Bid | `adid` | string | 권장 |
| Bid | `crid` | string | 권장 |
| Bid | `adomain` | array of string | 권장 |
| Bid | `mtype` | integer | 권장 |
| Bid | `nurl` | string | 선택 |
| Bid | `burl` | string | 선택 |
| Bid | `lurl` | string | 선택 |

---

## mtype → adm 포맷 매핑

| mtype | 광고 유형 | adm 포맷 |
|-------|-----------|-----------|
| `1` | Banner | HTML 또는 VAST URL (드문 케이스) |
| `2` | Video | VAST XML 문자열 |
| `3` | Audio | DAAST XML 문자열 |
| `4` | Native | Native Response JSON 문자열 |

> **💡 Tip:** Video adm 주의 — `mtype=2` 일 때 `adm`은 VAST XML 전체 문자열. VAST URL이 아님.

---

## Substitution Macros 전체 목록

| 매크로 | 설명 |
|--------|------|
| `${AUCTION_ID}` | BidRequest.id |
| `${AUCTION_BID_ID}` | BidResponse.id |
| `${AUCTION_IMP_ID}` | Imp.id |
| `${AUCTION_SEAT_ID}` | SeatBid.seat |
| `${AUCTION_AD_ID}` | Bid.adid |
| `${AUCTION_PRICE}` | 낙찰 가격 (암호화 필요) |
| `${AUCTION_LOSS}` | 낙찰 실패 사유 코드 (lurl 전용) |
| `${AUCTION_CURRENCY}` | 낙찰 통화 |
| `${AUCTION_MBR}` | Market Bid Ratio (낙찰가/입찰가) |
| `${AUCTION_MIN_TO_WIN}` | 낙찰에 필요한 최소 가격 |
| `${AUCTION_EXCHANGE_ID}` | 익스체인지 ID |
| `${AUCTION_DEAL_ID}` | Deal.id (PMP 거래 시) |

---

## No-Bid Reason (nbr) 코드 전체

| 코드 | 의미 |
|------|------|
| `0` | Unknown Error |
| `1` | Technical Error |
| `2` | Invalid Request |
| `3` | Known Web Spider |
| `4` | Suspected Non-Human Traffic |
| `5` | Cloud, Data Center, Proxy IP |
| `6` | Unsupported Device |
| `7` | Blocked Publisher or Site |
| `8` | Unmatched User |
| `9` | Daily Reader Cap Met |
| `10` | Daily Domain Cap Met |

---

## AdCOM Enum 빠른 참조

### DeviceType

| 값 | 의미 |
|----|------|
| 1 | Mobile/Tablet |
| 2 | Personal Computer |
| 3 | Connected TV |
| 4 | Phone |
| 5 | Tablet |
| 6 | Connected Device |
| 7 | Set Top Box |

### ConnectionType

| 값 | 의미 |
|----|------|
| 0 | Unknown |
| 1 | Ethernet |
| 2 | WiFi |
| 3 | Cellular (Unknown Gen) |
| 4 | 2G |
| 5 | 3G |
| 6 | 4G |
| 7 | 5G |

### VideoPlcmt (배치 유형)

| 값 | 의미 |
|----|------|
| 1 | Instream |
| 2 | Accompanying Content |
| 3 | Interstitial |
| 4 | No Content/Standalone |

### PlaybackMethod

| 값 | 의미 |
|----|------|
| 1 | Auto-play, Sound On |
| 2 | Auto-play, Sound Off |
| 3 | Click-to-play |
| 4 | Mouse-over |
| 5 | Entering Viewport, Sound On |
| 6 | Entering Viewport, Sound Off |

### CreativeSubtype / Protocol (Video)

| 값 | 의미 |
|----|------|
| 1 | VAST 1.0 |
| 2 | VAST 2.0 |
| 3 | VAST 3.0 |
| 4 | VAST 1.0 Wrapper |
| 5 | VAST 2.0 Wrapper |
| 6 | VAST 3.0 Wrapper |
| 7 | VAST 4.0 |
| 8 | VAST 4.0 Wrapper |

---

## 경매 가격 체크

```
Floor Price 우선순위 (높을수록 우선):
1. Deal.bidfloor          ← PMP 딜 존재 시 최우선
2. DurFloors[n].bidfloor  ← 영상 길이별 플로어 (DOOH/Video)
3. Imp.bidfloor           ← 기본 인벤토리 플로어
```

> **⚠️ Warning:** 필수 체크
> - `bidfloorcur` 미명시 시 USD 기본값
> - `Bid.price` < 적용 floor → 낙찰 불가
> - 2nd-price 경매(`at=2`): 낙찰가 = 2위 입찰가 + 최소단위

---

## Privacy 필드 빠른 참조

| 필드 | 위치 | 의미 |
|------|------|------|
| `regs.coppa` | BidRequest.regs | 1 = COPPA 적용 (아동 보호) |
| `regs.gdpr` | BidRequest.regs | 1 = GDPR 적용 |
| `regs.us_privacy` | BidRequest.regs | CCPA 문자열 (예: `1YNN`) |
| `user.consent` | BidRequest.user | GDPR TCF 동의 문자열 (Base64) |
| `regs.gpp` | BidRequest.regs | GPP 문자열 (신규 글로벌 표준) |
| `regs.gpp_sid` | BidRequest.regs | 적용된 GPP 섹션 ID 목록 |

---

## nurl vs burl vs lurl 비교표

| 항목 | nurl | burl | lurl |
|------|------|------|------|
| 명칭 | Win Notice URL | Billing Notice URL | Loss Notice URL |
| 트리거 시점 | 낙찰 즉시 (경매 결과) | 과금 이벤트 발생 시 | 낙찰 실패 시 |
| 호출 주체 | SSP/Exchange | SSP/Exchange | SSP/Exchange |
| 가격 포함 | `${AUCTION_PRICE}` | `${AUCTION_PRICE}` | - |
| 주요 사용 | 낙찰 알림, 가격 확인 | 실제 과금 기준 | 패인 분석 |
| 매크로 | `${AUCTION_PRICE}` 등 | `${AUCTION_PRICE}` 등 | `${AUCTION_LOSS}` 등 |

> **📝 Note:** `nurl`과 `burl`은 별개. 둘 다 보낼 수 있으며, 과금은 `burl` 기준이 표준.
