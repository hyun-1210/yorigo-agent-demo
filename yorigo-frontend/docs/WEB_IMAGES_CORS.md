# Why images don’t show on Flutter Web (Chrome, Safari)

Recipe thumbnails, review photos, and profile pictures often **don’t load on Flutter Web** (you see grey boxes or icons instead) while they work on Android/iOS. That’s usually due to **CORS (Cross-Origin Resource Sharing)**.

## What’s going on

- On **mobile**, the app loads images directly; there’s no browser CORS check.
- On **web**, the app runs in the browser. When it loads an image from Firebase Storage (or another domain), the browser does a cross-origin request. If the **Storage bucket doesn’t send the right CORS headers**, the browser blocks the image and Flutter’s `Image.network` fails, so you see the error placeholder (icon/grey box).

So: **images fail on web when the image server (e.g. Firebase Storage) is not configured for CORS.**

## Fix: Configure CORS on your Firebase Storage bucket

1. **Install Google Cloud SDK** (if you don’t have it), so you have `gsutil`:
   - https://cloud.google.com/sdk/docs/install

2. **Sign in and set project:**
   ```bash
   gcloud auth login
   gcloud config set project yorigo-f7408
   ```

3. **Use the CORS config in this repo**  
   In the project root (`yorigo-frontend`) there is `storage_cors.json`. It allows `GET`/`HEAD` from any origin. For production you can restrict `origin` to your real app URLs, e.g.:
   ```json
   "origin": ["https://yorigo-f7408.web.app", "https://yorigo-f7408.firebaseapp.com", "http://localhost:5000"]
   ```

4. **Apply CORS to your Storage bucket**  
   Firebase typically uses a bucket like `yorigo-f7408.appspot.com` or `yorigo-f7408.firebasestorage.app`. List buckets if needed:
   ```bash
   gsutil ls
   ```
   Then (replace `BUCKET_NAME` with your actual bucket, e.g. `yorigo-f7408.appspot.com`):
   ```bash
   cd path/to/yorigo-frontend
   gsutil cors set storage_cors.json gs://BUCKET_NAME
   ```

5. **Confirm:**
   ```bash
   gsutil cors get gs://BUCKET_NAME
   ```

After this, **reload your Flutter web app** (e.g. in Chrome). Recipe images on the home screen, review photos in the community/후기 section, and profile pictures should load as long as the URLs themselves are correct.

## If images still don’t show

- Check the browser **Network** tab: do the image requests return **200** or **4xx/5xx**? Do you see a **CORS error** in the console?
- Ensure the recipe/review documents actually have **thumbnailUrl** / **photoUrl** (or **photo_url**) set in Firestore.
- For Firebase Storage, ensure your **Storage security rules** allow read access for those image paths.
