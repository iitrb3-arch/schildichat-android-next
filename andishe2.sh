set -euo pipefail
echo "Detect modules…"
mapfile -t MODULES < <(git ls-files | grep -E 'src/main/AndroidManifest.xml$' | sed 's#/src/main/AndroidManifest.xml##' | sort -u)
echo "Modules: ${MODULES[*]}"

echo "Enforce minSdk=23 targetSdk=34…"
for f in $(git ls-files | grep -E '^(.*)/build.gradle(.kts)?$'); do
  sed -E -i \
    -e 's/(minSdk\s*=?\s*)[0-9]+/\123/g' \
    -e 's/(minSdkVersion\s*=?\s*)[0-9]+/\123/g' \
    -e 's/(targetSdk\s*=?\s*)[0-9]+/\134/g' \
    -e 's/(targetSdkVersion\s*=?\s*)[0-9]+/\134/g' \
    "$f" || true
done

echo "Enable shrink/proguard on release…"
for f in $(git ls-files | grep -E '^.*app.*/build.gradle(.kts)?$'); do
  if ! grep -q "buildTypes" "$f"; then
    cat >> "$f" <<'EOF'
android {
  buildTypes {
    release {
      minifyEnabled true
      shrinkResources true
      proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
    }
  }
  packagingOptions {
    resources {
      excludes += ['META-INF/*']
    }
  }
  compileOptions {
    sourceCompatibility JavaVersion.VERSION_17
    targetCompatibility JavaVersion.VERSION_17
  }
}
EOF
  else
    sed -i -E "s/release\s*\\{[^}]*\\}/release { minifyEnabled true\nshrinkResources true\nproguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro' }/g" "$f" || true
  fi
done

echo "Set applicationId & app_name…"
for f in $(git ls-files | grep -E '^.*app.*/build.gradle(.kts)?$'); do
  if grep -q 'applicationId' "$f"; then
    sed -E -i "s#applicationId\\s+\"[^\"]+\"#applicationId \"${APP_ID}\"#g" "$f"
  else
    sed -E -i "s#(defaultConfig\\s*\\{)#\\1\n        applicationId \"${APP_ID}\"#g" "$f" || true
  fi
done
for s in $(git ls-files | grep -E 'src/main/res/values.*/strings.xml$'); do
  sed -i 's#<string name="app_name">[^<]*</string>#<string name="app_name">'${APP_NAME}'</string>#g' "$s" || true
  sed -i "s#Element#${BRAND_FA}#g" "$s" || true
  sed -i "s#ELEMENT#${BRAND_FA}#g" "$s" || true
  sed -i "s#element#${BRAND_FA}#g" "$s" || true
done

echo "Locales fa/en only…"
for m in "${MODULES[@]}"; do
  mkdir -p "$m/src/main/res/xml"
  cat > "$m/src/main/res/xml/locales_config.xml" <<EOF
<locale-config xmlns:android="http://schemas.android.com/apk/res/android">
    <locale android:name="fa"/>
    <locale android:name="en"/>
</locale-config>
EOF
  MAN="$m/src/main/AndroidManifest.xml"
  if ! grep -q 'android:localeConfig' "$MAN"; then
    sed -i 's#<application #<application android:localeConfig="@xml/locales_config" #g' "$MAN"
  fi
done
for d in $(git ls-files | grep -E 'src/main/res/values-[a-zA-Z-]+' | sed 's#/[^/]*$##' | sort -u); do
  if [[ "$d" != *"/values-fa" && "$d" != *"/values-en" && "$d" != *"/values" ]]; then
    git rm -r -f "$d" || true
  fi
done
for m in "${MODULES[@]}"; do
  MAN="$m/src/main/AndroidManifest.xml"
  if ! grep -q 'android:supportsRtl' "$MAN"; then
    sed -i 's#<application #<application android:supportsRtl="true" #g' "$MAN"
  fi
done

echo "Hard-set homeserver ${HOMESERVER_URL} & strip UI (server picker / signup / forgot / invite / QR / support / feedback / legal)…"
git ls-files | grep -E '\.kt$|\.java$|\.xml$' | while read -r f; do
  sed -i "s#https://matrix.org#${HOMESERVER_URL}#g" "$f" || true
  sed -i "s#https://.*\\.matrix\\.org#${HOMESERVER_URL}#g" "$f" || true
  sed -i "s#defaultHomeserver\" value=\"[^\"]*#defaultHomeserver\" value=\"${HOMESERVER_URL}#g" "$f" || true
done
for x in $(git ls-files | grep -E 'src/main/res/menu/.*\.xml$'); do
  sed -i -E '/invite|qr|support|feedback|bug|report|share|contact|friend|legal/d' "$x" || true
done

# Help/About to brand
for s in $(git ls-files | grep -E 'src/main/res/values.*/strings.xml$'); do
  if grep -q '<string name="about">' "$s"; then
    sed -i 's#<string name="about">[^<]*</string>#<string name="about">'"${BRAND_FA}"'</string>#' "$s"
  else
    sed -i 's#</resources>#<string name="about">'"${BRAND_FA}"'</string>\n</resources>#' "$s"
  fi
  if grep -q '<string name="help">' "$s"; then
    sed -i 's#<string name="help">[^<]*</string>#<string name="help">'"${BRAND_FA}"'</string>#' "$s"
  else
    sed -i 's#</resources>#<string name="help">'"${BRAND_FA}"'</string>\n</resources>#' "$s"
  fi
done

echo "Admin-only note (implement check in code later if needed)…"
echo "Admin-only room/channel creation policy. Expected admin: ${ADMIN_ID}" > ADMIN_GATE_NOTE.txt

echo "Mark applied and try commit to main…"
echo "applied" > "${MARKER_FILE}"
git add -A
git commit -m "Andishe2: one-time transform (homeserver=${HOMESERVER_URL}, fa/en only, remove invites/qr/support, branding ${BRAND_FA}, minSdk=23, shrink)."

if git push origin HEAD:main; then
  echo "::notice::Pushed to main"
else
  echo "::warning::Push to main blocked (branch protection?). Creating branch & PR…"
  git checkout -b "${FALLBACK_BRANCH}"
  git push -u origin "${FALLBACK_BRANCH}"
  gh pr create --title "Andishe2 changes" --body "One-time transform ready. Merge to apply permanently." --base main --head "${FALLBACK_BRANCH}" || true
fi
