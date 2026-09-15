[README.md](https://github.com/user-attachments/files/32240147/README.md)
# Forecast# Voorraadhorizon

Voorraadprognose voor BankhoesDiscounter, volledig gebouwd op StockItUp-data.

Beantwoordt drie vragen per SKU:

1. **Wanneer loopt dit artikel leeg?**
2. **Wanneer loopt het ná de eerstvolgende levering wéér leeg?**
3. **Hoeveel dozen moeten er nu besteld worden om dat te voorkomen?**

Peildatum van de data in deze map: **14 september 2026**.

---

## ⚠️ Zet deze repository op Private

Deze map bevat bedrijfsgevoelige gegevens: voorraadstanden, **inkoopprijzen per stuk**,
leveranciersnaam, verkoopsnelheden per artikel en openstaande klantorders.

Kies bij het aanmaken van de repository **Private**, niet Public. Op Public is alles
voor iedereen op internet te lezen en te downloaden, ook door concurrenten.
Een repository die eenmaal Public is geweest kan al gekopieerd zijn — later op Private
zetten haalt dat niet terug.

---

## Snel starten

Dubbelklik **`dashboard.html`**. Het opent in je browser en werkt zonder internet,
zonder installatie en zonder server — alle data zit in het bestand zelf.

---

## Wat staat waar

| Bestand | Wat het is |
|---|---|
| `dashboard.html` | **Het dashboard.** Kant en klaar, dubbelklikken en klaar. |
| `template.html` | De broncode van het dashboard, met `/*__DATA__*/null` op de plek waar de data in komt. Hier pas je het uiterlijk en de rekenregels aan. |
| `rebuild.ps1` | Bouwt `dashboard.html` opnieuw uit de ruwe data. Rechtsklik → *Run with PowerShell*. |
| `.gitignore` | Vertelt GitHub welke rommelbestanden het mag negeren. |
| `data/dataset.json` | De verwerkte data die in het dashboard zit. |
| `data/raw_*.json` | De ruwe exports uit StockItUp. |
| `scripts/` | De verwerkingsstappen, zie hieronder. |
| `PIPELINE-FIX.md` | De fix die in de datapijplijn nodig is om inkooporderregels binnen te krijgen. |

## Opnieuw bouwen met nieuwe data

Vervang de bestanden in `data/` door verse exports uit StockItUp en draai:

```powershell
.\rebuild.ps1 -Peildatum 2026-09-14
```

**Geef altijd de peildatum mee**: dat is de dag waarop je de exports hebt opgehaald, niet de dag
waarop je het script draait. Laat je hem weg, dan wordt het vandaag, en zodra die twee verschillen
rekent de projectie dagen verkoop mee die al geweest zijn.

## De scripts

| Script | Wat het doet |
|---|---|
| `build.ps1` | Maakt van de ruwe exports één `dataset.json`: retouren eraf, sets uitgesplitst naar componenten, inkooporderregels gekoppeld op EAN. |
| `inject.ps1` | Plakt de dataset in de template. |
| `serve.ps1` | Start een lokale webserver op poort 8099, handig bij het ontwikkelen. |
| `pdftext.ps1` | Haalt tekst uit de picklijst-PDF's. |
| `parse-po.ps1` | Maakt records van die tekst en controleert de totalen tegen de API. |
| `orders-vrij.ps1` | Rekent uit hoeveel **klantorders** er verzendbaar worden na elke container. |
| `backorder-afbouw.ps1` | Hetzelfde maar in stuks, met en zonder doorverkoop. |
| `geen-aanbod.ps1` | Lijst de artikelen die besteld moeten worden maar geen leveranciersprijs of doosinhoud hebben. |
| `container-voorstel.ps1` | Voorstel voor de vulling van een volgende container. |
| `analyse-leeg.ps1` | Analyse van de artikelen die nu al leeg staan. |

## Hoe de berekening werkt

Per artikel, dag voor dag vooruit:

```
saldo = max(0, vrije_voorraad − backorder)

voor elke dag d in 0..210:
    saldo += aankomsten[d]          # inkooporders op hun ETA
    saldo −= verkoop_per_dag
    als saldo < 0:
        saldo = 0                   # niet-geleverde vraag telt als gemiste omzet
        markeer dag d als "uit voorraad"

leeg_op       = eerste dag met saldo 0
terug_op      = eerste dag daarna met saldo > 0
weer_leeg_op  = begin van het tweede gat
besteldatum   = leeg_op − levertijd
tekort        = ceil(verkoop_per_dag × dekking) − saldo[levertijd]
dozen         = ceil(tekort ÷ doosinhoud)
```

Instelbaar in het dashboard: levertijd (standaard 90 dagen), gewenste dekking
(standaard 90 dagen) en het venster waarover het verkooptempo wordt gemeten (7, 28 of 90 dagen).

## Wat er nog geregeld moet worden

1. **Sets** — 150 setrelaties, tot meerdere niveaus diep. Vraag moet naar componentniveau
   gerold worden; beschikbaarheid van een set is die van het krapste onderdeel.
2. **Ontbrekende leveranciersdata** — 19 artikelen die besteld moeten worden hebben geen prijs
   of doosinhoud, samen 2.432 stuks. Die vallen daardoor buiten het doosaantal.
3. **Geen index op `stockitup_inventory`** (5,7 miljoen regels). Elke query over de hele tabel
   loopt in een time-out.
4. **Seizoen** — er wordt nu met een vlak gemiddelde gerekend. Twee jaar orderhistorie staat klaar.
5. **Containervulling** — de omrekening naar containers is een schatting op het gemiddelde van de
   laatste drie zendingen, zolang volume per doos ontbreekt.

Deze vijf staan ook onderaan in het dashboard zelf.
