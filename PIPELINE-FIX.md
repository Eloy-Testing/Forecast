# Pipeline-fix: inkooporderregels van lopende containers ontbreken

**Datum:** 2026-09-14
**Impact:** blokkeert koppeling "welke SKU komt wanneer binnen" in het voorraaddashboard
**Connector:** `stockitup` (StockItUp), warehouse-landing `stockitup_api_records`

---

## Het probleem

Voor **lopende** inkooporders (`status = "active"`) levert de warehouse geen regels per product.
Het dashboard weet daardoor wél dat er op 17 september 3.836 stuks landen, maar niet wélke SKU's.

De endpoint-catalogus classificeert `getSupplierOrder` als overbodig:

```
operation_id        : getSupplierOrder
path_template       : /supplier-orders/{order_id}/
disposition         : duplicate_projection
warehouse_contract  : "SupplierOrder including items retained by stockitup_supplier_orders_*"
```

Die aanname klopt niet. `listSupplierOrders` (`/supplier-orders/`) embedt `items` **alleen bij
afgeronde orders**. Bij actieve orders komt het veld als lege array mee.

## Bewijs

Alle zes actieve inkooporders, over elke gecapturede versie:

```sql
SELECT entity_key,
       MAX(json_array_length(json_extract(raw_json,'$.items'))) AS max_items,
       COUNT(*) AS versies
FROM stockitup_api_records
WHERE resource = 'stockitup_supplier_orders_active'
  AND rowid > 1400000
GROUP BY entity_key;
```

| entity_key | max_items | versies |
|---|---|---|
| id:10 | 0 | 6 |
| id:11 | 0 | 6 |
| id:14 | 0 | 6 |
| id:15 | 0 | 6 |
| id:18 | 0 | 6 |
| id:19 | 0 | 6 |

Ter vergelijking, dezelfde query op `stockitup_supplier_orders_completed` geeft `max_items`
gelijk aan `item_count` (bijv. id:13 → 2 regels, id:4 → 73 regels). De lege array is dus
specifiek voor `status = "active"`, niet een algemeen sync-probleem.

## De fix

Herclassificeer `getSupplierOrder` van `duplicate_projection` naar `detail_queue`:

| veld | waarde |
|---|---|
| `operation_id` | `getSupplierOrder` |
| `method` / `path` | `GET /supplier-orders/{order_id}/` |
| `disposition` | `detail_queue` |
| `parent` | `stockitup_supplier_orders_active` → `entity_key` (order-id) |
| `warehouse_contract` | `stockitup_supplier_order_items` |
| frequentie | mag laag — orders wijzigen hooguit dagelijks, en het zijn er ~6 |

Alleen de queue vullen vanuit **active** (en eventueel `cancelled`); voor `completed` is de
lijstprojectie al volledig, daar zou de detailcall echt dubbel werk zijn.

## Wat het oplevert

Regelschema zoals het nu al terugkomt bij afgeronde orders — dit is een echte regel uit id:13:

```json
{
  "id": 338,
  "product_id": 1425,
  "sku": "Tobi's House - Hondenvoerbak",
  "ean": "8720892561305",
  "quantity": 40,
  "delivery_date": "2026-08-06",
  "arrived_quantity": 0,
  "open_quantity": 40,
  "cancelled_quantity": 0,
  "current_stock": 36,
  "own_stock": 36,
  "warehouse_inbound_stock": 0,
  "sold_last_28_days": 0,
  "sold_last_7_days": 0
}
```

`product_id` sluit direct aan op `stockitup_inventory.product_id` en op `product_id` in
`order_items`, dus er is geen mapping-laag nodig. Met `delivery_date` per regel wordt de ETA
bovendien per SKU in plaats van per container — sommige regels in één order kunnen afwijken.

Daarmee kan het dashboard:

- inkomende stuks per SKU op de tijdlijn zetten naast de leegloopdatum;
- de dekking doorrekenen mét onderweg zijnde voorraad, niet alleen met wat er nu ligt;
- per SKU melden of de eerstvolgende container de backorders dekt;
- `arrived_quantity` volgen om deelleveringen te verwerken.

---

## Twee kleinere observaties

**1. De `_current`-views zijn onbruikbaar via `query_data`.**
`stockitup_api_records_current`, `stockitup_inventory_current` en `stockitup_warehouses_current`
geven een timeout, ook op `SELECT ... LIMIT 5`. De basistabellen werken wel. Workaround die nu
gebruikt wordt: laatste versie per entiteit ophalen via `MAX(rowid)` binnen een rowid-venster,
en de laatste voorraadcapture via `stockitup_captures WHERE status='complete'`.

Aanvullend ontbreekt een index op `stockitup_api_records(resource, source_updated_at)`; elke
filter op die kolommen doet nu een volledige scan over ~1,6 mln rijen en loopt tegen de timeout.
Een index daarop maakt het dashboard direct een stuk goedkoper te verversen.

**2. Capture-failures zijn verwaarloosbaar.**
6 van 724 captures in de laatste twee dagen faalden (0,8%). Geen actie nodig — wel reden om in
queries altijd op `status = 'complete'` te filteren in plaats van op de nieuwste capture.
