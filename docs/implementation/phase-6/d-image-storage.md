# D. Image storage

## 1. Approach (Phase 3 contracts §4)

Supabase Storage holds product images in a **private** bucket, `store-media`. The app uploads with the seller's JWT, then references the object from the product in the same save. Images are displayed through **signed URLs valid for one hour**. No public URLs exist and no privileged key is involved.

## 2. Upload pipeline

1. **Pick:** `image_picker` 1.2.4, from the camera or the gallery. The platform is asked for a bounded JPEG (at most 3200 px, quality 95), which also converts HEIC on iOS. `requestFullMetadata: false` avoids needing photo-library permission.
2. **Check:** files over **10 MB** before compression are refused ("larger than 10 MB"). Undecodable files are refused ("isn't a photo Aisellia can use").
3. **Prepare** in a background isolate (`image` 4.12.0):
   - apply the EXIF orientation;
   - **centre-crop to 1:1** (Phase 2 §7);
   - resize to at most **1600 px**;
   - re-encode as **JPEG quality 80** from a fresh image, with **no EXIF, GPS, text or ICC data** (BR-71);
   - if the result is still over 2 MiB, retry at quality 70, then 60.

   Tests check a real JPEG that carried GPS data: the output has none.
4. **Upload** to `{store_id}/products/{product_id}/{uuid}.jpg` with `upsert: false`, a 60-second timeout and content type `image/jpeg`. The product id comes from the client, so photos upload as soon as they're picked, before the first save. Each tile shows its own progress ring; it is indeterminate, because the Storage SDK reports no byte counts.
5. **Save:** the product's `images` list is the new state, and its order is the display order (position 0 is the main photo). `api.upsert_product` checks that every path belongs to this store and product and that the object exists, then writes `product_images`.

## 3. Failures and duplicates

- **A failed upload** (network, refusal) shows "Not uploaded — Retry" on its tile. Tapping retries the same prepared bytes. Save stays enabled; the failed photo isn't saved and the note says so (US-012). Save waits only while an upload is still running.
- **Repeated taps:** one tap creates one tile and one upload. Uploads are never overwritten (no upsert, no update policy). Each new photo gets its own uuid path, so a retry after a lost answer creates at most one unreferenced object, which the cleanup removes.
- **Missing or broken images:**
  - no photo shows the neutral package placeholder;
  - an image that fails to load shows the placeholder with a broken-image mark, and the detail view adds "Image unavailable";
  - a signed URL that can't be created is treated the same way.

## 4. Replacing and removing

- In the editor's viewer (PR-07): **Set as main**, **Replace** (pick, upload, swap in place) and **Remove** (with confirmation). Nothing changes on the server until Save.
- After a successful save, the server returns `removed_image_paths`, and the app deletes those objects. The delete policy refuses objects that are still referenced, so an image in use can't be lost to a race.
- **Uploads that are never saved** (the editor was discarded or closed) are deleted when the editor closes.

## 5. Abandoned objects (cleanup)

Objects can still be left behind: a deletion that failed offline, an app that was killed mid-edit, or a purged account. `internal.orphaned_media(older_than default 24 h)` lists objects in the bucket that no product references.

Objects must be deleted through the Storage API; direct SQL deletes are blocked by `storage.protect_delete`. The scheduled worker that calls the API with the service role (Phase 3 ADR-008: pg_cron plus an Edge Function) **is not built in this phase**, because it needs deployed infrastructure. Until then the list can be purged manually. See [G §5](g-phase-6-completion-report.md#5-known-limitations).

## 6. Display

- `SupabaseMediaStore.image(path)` creates a signed URL (1 h) with the seller's token and caches it for 50 minutes, so the image cache hits.
- Images fade in over 150 ms. Thumbnails are 56 dp in lists and 96 dp in the editor; the detail view uses a full-width 1:1 gallery with page dots, and a pinch-to-zoom viewer.

## 7. Configuration

- `supabase/config.toml`: `[storage] enabled = true`, upper bound 5 MiB, S3 protocol off.
- The bucket, its limits and its policies are created by the **migration**, not by `config.toml`. `supabase db push` therefore gives a hosted project exactly the same setup. Check in the dashboard that Storage → `store-media` is **private**, with a 2 MiB limit and `image/jpeg` only.
- iOS `Info.plist`: `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` (English). Android needs no extra permission for the picker intents.
- No credentials are involved anywhere in this setup.
