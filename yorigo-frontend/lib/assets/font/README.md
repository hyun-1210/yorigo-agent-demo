# Bundled fonts (Pretendard, Caveat, Inter)

The app uses these from `pubspec.yaml` (no Google Fonts package or network required).

**Figma-derived UI (e.g. temp screen):** **Pretendard** is used wherever Figma specifies Inter — same weights (400–900). Files from `Pretendard-1.3.9` (public/static .otf). **Caveat** is used for “Weekly Plan.” **Inter** remains in pubspec for any other screens that reference it.

## Why don’t my fonts look like Figma?

It’s usually **not** that the files are “bad.” It’s that **Figma uses a specific build** of each font (the one from Google Fonts). If your files came from somewhere else, or an older/different package, they can be a different design or version, so:

- **Caveat** might not look like Caveat (e.g. different stroke, proportions, or even a different script font if the file was mislabeled).
- **Inter** might look slightly different in weight or metrics.

So: the font files you have are loaded correctly; to **match Figma**, you need the **same** font files Figma uses.

## Replace with the same fonts Figma uses

Figma uses **Google Fonts**. Use these steps so your app uses the exact same builds:

### 1. Caveat

1. Open **https://fonts.google.com/specimen/Caveat**
2. Click **“Download family”** (top right). You get a zip.
3. Unzip. You’ll see e.g. `Caveat-Regular.ttf`, `Caveat-Bold.ttf`, etc.
4. For this project we only need **Bold (700)** for “Weekly Plan”:
   - Copy **`Caveat-Bold.ttf`** from the zip into  
     `yorigo-frontend/lib/assets/font/Caveat/`  
     and **overwrite** the existing `Caveat-Bold.ttf`.

Your `pubspec.yaml` already has:

```yaml
- family: Caveat
  fonts:
    - asset: lib/assets/font/Caveat/Caveat-Bold.ttf
      weight: 700
```

No change needed there.

### 2. Inter

1. Open **https://fonts.google.com/specimen/Inter**
2. Click **“Download family”**. Unzip.
3. From the zip, copy into `yorigo-frontend/lib/assets/font/Inter/` (overwrite existing):
   - **Inter-Regular.ttf** (or .otf if the zip has that)
   - **Inter-Medium.ttf**
   - **Inter-SemiBold.ttf**
   - **Inter-Bold.ttf**
   - **Inter-ExtraBold.ttf**
4. If your Figma design uses **Black (900)** and you want it to match exactly, also copy **Inter-Black.ttf** into `Inter/` and add this under the Inter family in `pubspec.yaml`:

```yaml
- asset: lib/assets/font/Inter/Inter-Black.ttf
  weight: 900
```

If the Google Fonts zip uses **.ttf** and your `pubspec` still says **.otf**, update the `asset` paths in `pubspec.yaml` to match the real filenames (e.g. `Inter-Regular.ttf` instead of `Inter-Regular.otf`).

### 3. Apply

- Run **`flutter pub get`** (or let your IDE do it).
- Do a **full restart** of the app (hot reload may not refresh fonts).

After this, Caveat and Inter in the app are the same builds as in Figma, so they should match.

## Other checks

- **Family name**  
  In code we use `fontFamily: 'Inter'` and `fontFamily: 'Caveat'`. The `family:` in `pubspec.yaml` must match exactly (case-sensitive). We have `family: Inter` and `family: Caveat` — no change needed.
- **Weights in code**  
  Only use weights you actually have in `pubspec`. If you don’t add Inter-Black (900), keep using `FontWeight.w800` for the heaviest Inter text so the bundled ExtraBold is used.
