#!/usr/bin/env bash
#
# 06_vercel_fix.sh — Vercel root directory sorunu icin yedek yapilandirma
#
# Repo kokunde calistir. Tek dosya ekler: apps/web/vercel.json
# Boylece root directory olarak "./" ya da "apps/web" secilmis olsa da
# derleme calisir.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "apps/web" ]; then
  echo "HATA: Bu script repo kokunde calistirilmali." >&2
  exit 1
fi

echo "==> apps/web/vercel.json"
cat > apps/web/vercel.json << 'ODK_EOF_0'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "buildCommand": "cd ../.. && pnpm --filter @odk/web build",
  "installCommand": "cd ../.. && pnpm install --frozen-lockfile=false",
  "outputDirectory": "dist",
  "framework": null
}
ODK_EOF_0

cat << 'ODK_DONE'

Eklendi: apps/web/vercel.json

Simdi iki yoldan biri:

  A) ONERILEN — root directory repo koku
     rm -rf .vercel
     vercel link          # dizin sorusuna ./ cevap ver
     vercel --prod

  B) root directory apps/web
     Vercel Dashboard -> Settings -> General
       "Include source files outside of the Root Directory
        in the Build Step" ayarini AC
     vercel --prod

Git:
  git add -A
  git commit -m "Vercel: apps/web icin yedek yapilandirma"
  git push
ODK_DONE
