#!/usr/bin/env python3
"""
Copy your Firebase service account JSON into the file the backend expects.

From repo root:
  python backend/scripts/setup_firebase_credentials.py path/to/your-key.json
  python backend/scripts/setup_firebase_credentials.py --stdin   # paste JSON, then Ctrl+Z Enter (Windows) or Ctrl+D (Mac/Linux)
"""
import json
import os
import sys

def main():
    backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = os.path.join(backend_dir, "firebase-service-account.json")

    if len(sys.argv) == 2 and sys.argv[1] == "--stdin":
        print("Paste your Firebase service account JSON (one line or multi-line), then press Ctrl+Z Enter (Windows) or Ctrl+D (Mac/Linux):")
        content = sys.stdin.read()
    elif len(sys.argv) == 2:
        src = os.path.normpath(sys.argv[1])
        if not os.path.isabs(src):
            src = os.path.abspath(src)
        if not os.path.exists(src):
            print(f"Error: File not found: {src}")
            sys.exit(1)
        with open(src, "r", encoding="utf-8") as f:
            content = f.read()
    else:
        print("Usage: python setup_firebase_credentials.py <path-to-service-account.json>")
        print("   or: python setup_firebase_credentials.py --stdin")
        print("Example: python backend/scripts/setup_firebase_credentials.py backend/firebase-key.json")
        sys.exit(1)

    try:
        data = json.loads(content.encode().decode("utf-8-sig"))
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON: {e}")
        sys.exit(1)
    if data.get("type") != "service_account" or "private_key" not in data:
        print("Error: Content does not look like a Firebase service account JSON (missing type or private_key).")
        sys.exit(1)

    with open(dest, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Created {dest}")
    print("Start the backend with: python backend/backend.py")

if __name__ == "__main__":
    main()
