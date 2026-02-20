# Outfit Studio — Digital Closet + Weather-Aware Outfit Planner (Flutter)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)
![Platform](https://img.shields.io/badge/Platforms-Android%20%7C%20iOS-222222)
![Storage](https://img.shields.io/badge/Storage-Local%20(JSON%20%2B%20Images)-6A5ACD)

A clean, local-first wardrobe app: add your clothes, filter your closet, generate outfit suggestions using **real weather** (Open‑Meteo), and track what you wore so the app avoids repeating the same pieces.

This repo is intentionally kept as a **single-file prototype (`main.dart`)** to make it easy to review and run. If you want a “production layout”, check the **Roadmap** section.

---

## Table of Contents (EN)
- [What This App Does](#what-this-app-does)
- [Core Features](#core-features)
- [How Outfit Suggestions Work](#how-outfit-suggestions-work)
- [Worn History (Giydim) Logic](#worn-history-giydim-logic)
- [Data Storage & Persistence](#data-storage--persistence)
- [Project Structure](#project-structure)
- [Tech Stack & Packages](#tech-stack--packages)
- [Setup & Run](#setup--run)
- [Permissions](#permissions)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)
- [Roadmap](#roadmap)
- [License](#license)

---

## What This App Does
Outfit Studio is built around a simple daily loop:

1) **Add clothes** to your closet (photo + tags).  
2) **Filter/search** your closet quickly.  
3) Open **Outfit Planner** and select a context (Cafe / Sport / Office / Dinner / Formal).  
4) The app fetches current weather using your location and suggests **Top 3 outfits**.  
5) Press **Giydim** when you wear one. It’s saved into history and the same items are penalized for a while so suggestions rotate.

---

## Core Features

### 1) Add Clothing (Kıyafet Ekle)
Add an item with:
- **Photo** (gallery via image_picker)
- **Category**: TOP / BOTTOM / OUTER / SHOES / ACCESSORY  
- **Color**: a predefined set (Black, White, Gray, Beige, Blue, Red, Green, Brown, Yellow, Purple)
- **Laundry State**:  
  - Temiz (ready)  
  - Kirli (dirty)  
  - Çamaşırda (laundry)
- **Warmth (multi-select)**:  
  - 1 = Thin (İnce)  
  - 2 = Medium (Orta)  
  - 3 = Warm (Kalın)
- **Occasion (multi-select)**:  
  - casual / sport / smart / formal
- **Note** (optional)

Accessory rule:
- If category is **ACCESSORY**, the item automatically supports all warmth levels (1,2,3).

### 2) Closet (Dolabım)
A grid view of your closet with:
- **Search** across category, color, note, original image name, warmths, occasions, laundry label
- Filters:
  - Category
  - Color
  - Occasion
  - Warmth
  - Laundry state
- **Tap** an item → details
- **Long press** → delete

### 3) Clothing Details + Edit
From the detail page:
- See key badges (category, color, laundry, warmth list, occasion list)
- Edit fields + replace photo
- Delete the item

### 4) Outfit Planner (Kombin Oluştur)
- Choose an **event/context**: Sport / Cafe / Office / Dinner / Formal
- Weather is fetched automatically; you can refresh manually
- The app generates up to **Top 3** outfit suggestions
- Requires at least **1 TOP + 1 BOTTOM**
- Optionally adds OUTER / SHOES / ACCESSORY when available

### 5) Outfit History (Geçmiş)
- Every “Giydim” creates a history entry with:
  - timestamp
  - chosen event
  - item ids
  - optional weather snapshot
- Manage history:
  - delete a single entry
  - clear all history

---

## How Outfit Suggestions Work
There is no ML model here. Suggestions are **rule-based** and scored.

### Step 1 — Build a candidate pool
The planner starts from your closet:
- First, it filters to **Temiz (ready)** clothes only.
- It tries to match the required **occasion** (derived from the event).
- If strict occasion filtering returns an empty pool, it falls back to all clean clothes.

### Step 2 — Split by category
It divides the pool into:
- TOP, BOTTOM, OUTER, SHOES, ACCESSORY

If TOP or BOTTOM is missing → no suggestions.

### Step 3 — Score items (`_itemScore`)
Each item gets a score based on:

**A) Warmth match (weather vs. item warmth tags)**
- exact match: +10
- off by 1: +3
- off by 2+ : -6

**B) Occasion match**
- if item supports desired occasion: +8

**C) Cooldown penalty (recently worn → penalize)**
Uses `lastWornAt`:
- < 24h: -25  
- < 48h: -14  
- < 72h: -8  
- < 7 days: -3  
- >= 7 days: 0

**D) Outer behavior**
- If category is OUTER:
  - Cold or raining: +6
  - Hot: -50 (almost never suggested)

**E) Neutral color bonus**
- Black/White/Gray/Beige: +1.5

### Step 4 — Score outfits (`_outfitScore`)
An outfit’s score is a weighted sum:
- TOP + BOTTOM: full weight
- SHOES: 0.7x
- ACCESSORY: 0.4x
- OUTER: 0.8x

Extra rules:
- If it’s cold/raining and there is **no outer**, penalty: -6
- Simple color pairing:
  - top.color == bottom.color: +3
  - if either is neutral: +2

### Step 5 — Pick Top 3 distinct outfits
The planner generates combinations (tops x bottoms, optionally outer/shoes/accessory), sorts by score, and returns the top 3 **unique** outfits.

---

## Worn History (Giydim) Logic
Pressing **Giydim** does two things:

1) Updates each involved clothing item’s `lastWornAt = now`
2) Adds a new history entry (OutfitLog) **if allowed**

Spam prevention:
- If the same outfit (same set of item IDs) already exists in history for the same event, it won’t be added again.
- If you delete that history entry, you can add it again.

Why this matters:
- Even if history blocks duplicates, updating `lastWornAt` ensures the scoring system reacts immediately and rotates suggestions.

---

## Data Storage & Persistence
Everything is local-only.

### Where images are stored
Images are copied into app documents directory:
- `.../outfit_images/<id>.<ext>`

### Where JSON is stored
- `.../items.json`

### JSON schema
`items.json` stores:
- `items`: list of `ClothingItem`
- `history`: list of `OutfitLog`

If you uninstall the app, the documents directory is removed → all data is lost.

---

## Project Structure
This repo is intentionally minimal:
- `main.dart` contains:
  - Domain models (ClothingItem, OutfitLog, LaundryState)
  - Stores (OutfitStore, WeatherStore)
  - UI pages (Home, Add Clothing, Closet, Planner, History, Edit/Detail)
  - Scoring + suggestion logic
  - Shared UI widgets

---

## Tech Stack & Packages
- Flutter (Material 3, dark theme UI)
- Local persistence (JSON file + copied images)
- Packages:
  - `image_picker` — pick images from gallery
  - `path_provider` — get app documents directory
  - `path` — safe path joining/ext handling
  - `geolocator` — location permission + coordinates
  - `http` — Open-Meteo weather calls

Weather provider:
- Open‑Meteo forecast endpoint (current + hourly)

---

## Setup & Run

### 1) Get dependencies
```bash
flutter pub get
```

### 2) Run on device/emulator
```bash
flutter run
```

### 3) Build release (example)
```bash
flutter build apk --release
```

---

## Permissions

### Android
You must configure permissions required by:
- `geolocator` (location)
- `image_picker` (photo access)

Check package docs if you see permission errors.

### iOS
Add to `Info.plist`:
- `NSLocationWhenInUseUsageDescription`
- `NSPhotoLibraryUsageDescription`

Without these, iOS will crash or deny access.

---

## Troubleshooting

### “Hava servisi hata verdi” / weather does not load
- Location services may be off
- App permission may be denied
- Open location settings and enable permission
- Try refreshing from the weather button

### Images not showing
- If a copied image file is missing, the UI shows a placeholder.
- If you frequently see placeholders, the file system copy may be failing on that device.

### No outfit suggestions
- You need at least:
  - 1 TOP
  - 1 BOTTOM
- And they must be marked as **Temiz** to be suggested (strict filter).

---

## Known Limitations
- Single-file prototype (not ideal for scale)
- Color pairing is intentionally simple
- Shoes/accessory selection can be improved to optimize per outfit instead of “best item always”
- No export/import yet (local only)

---

## Roadmap
If you want to take this beyond prototype:
- Split into folders:
  - `models/`, `stores/`, `pages/`, `widgets/`, `services/`
- Add export/import (zip images + JSON)
- Add “Favorites” + manual outfit builder
- Improve scoring:
  - real color harmony
  - seasonal tags
  - item style tags (streetwear, classic, etc.)
- Optional: Firebase sync

---

## License
Prototype / educational use. Add a license (MIT/Apache-2.0) if you publish.

---

<br/>

# Outfit Studio — Dijital Dolap + Hava Durumuna Göre Kombin Önerisi (Flutter)

Dolabını fotoğraflarla dijitalleştir, filtrele, hava durumuna göre kombin önerisi al ve “giydim” diyerek geçmiş tut. Uygulama local-first çalışır: tüm veriler **telefonun içinde** kalır (JSON + görseller).

Bu repo özellikle hızlı inceleme/demonstrasyon için **tek dosya (`main.dart`)** halinde tutuldu. Proje büyütülecekse aşağıdaki **Yol Haritası** bölümüne bak.

---

## İçindekiler (TR)
- [Uygulama Ne Yapıyor?](#uygulama-ne-yapıyor)
- [Ana Özellikler](#ana-özellikler)
- [Kombin Önerisi Nasıl Çalışıyor?](#kombin-önerisi-nasıl-çalışıyor)
- [Giydim Mantığı ve Geçmiş](#giydim-mantığı-ve-geçmiş)
- [Kalıcılık ve Dosya Yapısı](#kalıcılık-ve-dosya-yapısı)
- [Kurulum ve Çalıştırma](#kurulum-ve-çalıştırma)
- [İzinler](#izinler)
- [Sık Karşılaşılan Sorunlar](#sık-karşılaşılan-sorunlar)
- [Bilinen Kısıtlar](#bilinen-kısıtlar)
- [Yol Haritası](#yol-haritası)

---

## Uygulama Ne Yapıyor?
Kullanım döngüsü çok net:

1) **Kıyafet ekle** (foto + etiketler).  
2) **Dolabım** ekranında arama/filtre yap.  
3) **Kombin Oluştur** ekranından bir ortam seç (Kafe/Spor/Ofis/Akşam/Formal).  
4) Uygulama konumdan hava durumunu çekip **Top 3 kombin** üretir.  
5) Giydiğinde **Giydim** dersin: geçmişe eklenir ve aynı parçalar bir süre puan kaybedip daha az önerilir (rotasyon).

---

## Ana Özellikler

### 1) Kıyafet Ekle
Bir kıyafet şunlarla eklenir:
- Fotoğraf (galeriden)
- Kategori: TOP / BOTTOM / OUTER / SHOES / ACCESSORY
- Renk: hazır listedeki renklerden biri
- Durum:
  - Temiz
  - Kirli
  - Çamaşırda
- Kalınlık (çoklu seçim):
  - 1 = İnce
  - 2 = Orta
  - 3 = Kalın
- Ortam (çoklu seçim):
  - günlük / spor / smart / formal
- Not (opsiyonel)

Aksesuar kuralı:
- ACCESSORY ise kalınlık otomatik 1-2-3 kabul edilir.

### 2) Dolabım
- Grid görünüm
- Arama: not/renk/kategori/kalınlık/ortam/durum gibi metinlerden
- Filtreler:
  - Kategori
  - Renk
  - Ortam
  - Kalınlık
  - Durum
- Tıkla: detay
- Uzun bas: sil

### 3) Detay + Düzenleme
- Kıyafet etiketleri “badge” olarak görünür
- Fotoğraf değiştirilebilir
- Silme işlemi yapılabilir

### 4) Kombin Oluştur
- Ortam seçimi: Spor / Kafe / Ofis / Akşam / Formal
- Hava durumuna göre hedef kalınlık belirlenir
- En fazla 3 kombin önerisi çıkar
- En az 1 TOP + 1 BOTTOM yoksa öneri üretmez
- Mümkünse dış giyim, ayakkabı, aksesuar ekleyebilir

### 5) Geçmiş
- Giydim ile kayıt düşer
- Tekil kombin silme
- Tüm geçmişi temizleme

---

## Kombin Önerisi Nasıl Çalışıyor?
Bu sistem “AI” değil; kural tabanlı bir puanlama.

### Adım 1 — Havuz
- Sadece **Temiz** kıyafetlerden başlar.
- Ortama uyan kıyafetleri tercih eder.
- Eğer çok dar kalırsa “temiz” olanların tamamına düşer.

### Adım 2 — Kategoriye ayır
TOP, BOTTOM, OUTER, SHOES, ACCESSORY şeklinde ayrılır.
TOP veya BOTTOM yoksa öneri yok.

### Adım 3 — Kıyafet puanı (`_itemScore`)
Kıyafete puan yazan ana parçalar:

A) Kalınlık uyumu
- tam uyum: +10
- 1 fark: +3
- 2+ fark: -6

B) Ortam uyumu
- istenen ortamı destekliyorsa: +8

C) Cooldown (yakın zamanda giyildiyse ceza)
- < 24 saat: -25
- < 48 saat: -14
- < 72 saat: -8
- < 7 gün: -3
- 7 gün+: 0

D) Dış giyim davranışı
- Soğuk/yağmurluysa dış giyime +6
- Hava sıcaksa dış giyime -50

E) Nötr renk bonusu
- Black/White/Gray/Beige: +1.5

### Adım 4 — Kombin puanı (`_outfitScore`)
- TOP + BOTTOM tam puan
- Ayakkabı 0.7 katsayı
- Aksesuar 0.4 katsayı
- Dış giyim 0.8 katsayı
- Soğuk/yağmur var ama dış giyim yoksa: -6 ceza
- Basit renk uyumu:
  - top ve bottom aynı renk: +3
  - biri nötr renkse: +2

### Adım 5 — Top 3
Kombinler listelenir, skorla sıralanır, ilk 3 farklı kombin döner.

---

## Giydim Mantığı ve Geçmiş
Giydim’e basınca:

1) Kombindeki kıyafetlerin `lastWornAt` alanı “şimdi” olur  
2) Geçmişe kayıt eklenir (uygunsa)

Spam engeli:
- Aynı kombin (aynı item seti) geçmişte zaten varsa tekrar eklenmez.
- O kaydı silersen tekrar eklenebilir.

Neden önemli?
- Geçmişe eklenmese bile `lastWornAt` güncellendiği için skor sistemi hemen etkilenir.

---

## Kalıcılık ve Dosya Yapısı
Her şey cihaz içinde saklanır:

- Görseller:
  - `.../outfit_images/<id>.<ext>`
- JSON:
  - `.../items.json`

Uygulamayı silersen tüm veriler gider.

---

## Kurulum ve Çalıştırma
```bash
flutter pub get
flutter run
```

---

## İzinler
Android:
- Konum (hava durumu)
- Fotoğraf/galeri erişimi

iOS:
Info.plist içine:
- NSLocationWhenInUseUsageDescription
- NSPhotoLibraryUsageDescription

---

## Sık Karşılaşılan Sorunlar
- Hava gelmiyor: konum kapalı olabilir veya izin reddedilmiştir.
- Öneri yok: TOP + BOTTOM yok ya da kıyafetler “Temiz” değildir.
- Foto görünmüyor: dosya taşındı/silindiyse placeholder gösterilir.

---

## Bilinen Kısıtlar
- Tek dosyalık prototip yapı
- Renk uyumu basit
- Ayakkabı/aksesuar seçimi daha akıllı optimize edilebilir
- Export/import yok

---

## Yol Haritası
- Projeyi dosyalara bölmek (models/stores/pages/widgets/services)
- Export/import eklemek
- Favoriler + manuel kombin oluşturma
- Skor sistemini geliştirmek (renk uyumu, sezon, stil etiketleri)
- Opsiyonel Firebase sync
