# Guía de publicación en Google Play Store — DSP BT Analyzer

Estado: **todo lo técnico está listo**. Los pasos que quedan son de la
consola web de Google Play y solo los puede hacer el dueño de la cuenta.

---

## Lo que YA está listo (hecho en este repositorio)

| Ítem | Estado | Detalle |
|---|---|---|
| `applicationId` único | ✅ | `io.github.oscarsapiensunal.dsp_bt_analyzer` (Play **rechaza** `com.example.*`; se usó el dominio del GitHub del autor). |
| Firma de release | ✅ | Keystore `android/upload-keystore.jks` (alias `upload`, RSA 2048, válido 27 años) + `android/key.properties`. **Ambos están fuera de git** (.gitignore) — ver "El keystore" abajo. |
| App Bundle (.aab) | ✅ | `build/app/outputs/flutter-apk/../bundle/release/app-release.aab`, firmado y verificado con `jarsigner`. Regenerar con: `flutter build appbundle --release` (con el `JAVA_TOOL_OPTIONS` del README si aplica). |
| `targetSdk` | ✅ | 36 — por encima del mínimo que exige Play (34+). |
| Versión | ✅ | `1.0.0+1` en pubspec.yaml (subir el `+N` en cada nueva subida a Play). |
| Manifest limpio | ✅ | Sin permisos de foreground service sin uso ni servicios fantasma; nombre visible "DSP BT Analyzer". |
| Política de privacidad | ✅ | `PRIVACY_POLICY.md` — publicar su URL de GitHub en la consola (ver paso 4). |

## El keystore — LÉEME ANTES DE SUBIR NADA

- Archivo: `android/upload-keystore.jks` · alias: `upload` · contraseña
  (store y key): `TeoInfoUNAL2026`.
- **Haz una copia de seguridad fuera del computador** (correo a ti mismo,
  Drive). Si se pierde el keystore, no se pueden publicar actualizaciones.
- Al crear la app en Play Console, acepta **"Play App Signing"** (opción por
  defecto): Google guarda la clave de firma final y este keystore queda solo
  como "clave de subida" — si algún día se pierde, se puede pedir a Google
  restablecerla. Es la opción segura.

## Pasos en Play Console (los haces tú)

1. **Cuenta de desarrollador**: [play.google.com/console](https://play.google.com/console)
   — pago único de USD $25. Con cuenta personal nueva, Google exige una
   **prueba cerrada con ≥12 testers durante 14 días** antes de poder pasar a
   producción — para la demo de la clase eso NO estorba: los testers de la
   prueba cerrada (tus compañeros) pueden instalarla desde Play de inmediato.
2. **Crear app**: nombre "DSP BT Analyzer", tipo App, gratis, idioma español
   (Latinoamérica).
3. **Subir el .aab**: Testing → Closed testing → crear track → subir
   `app-release.aab` → añadir los correos de los testers (lista de Gmail).
4. **Política de privacidad**: en "App content", pegar la URL:
   `https://github.com/OscarSapiensunal/TeoInfo-Proyect/blob/main/PRIVACY_POLICY.md`
5. **Declaraciones de contenido** (App content, todas obligatorias):
   - *Data safety*: declarar que la app **no recolecta ni comparte datos**
     (es la verdad: no hay internet, no hay servidores — ver PRIVACY_POLICY).
   - *Permisos sensibles*: micrófono → "comunicación de voz en tiempo real
     entre dos dispositivos"; ubicación → "requisito de Android ≤11 para el
     escaneo Bluetooth; la app no usa la posición".
   - Clasificación de contenido (cuestionario IARC): app utilitaria, sin
     contenido sensible → clasificación libre.
   - Público objetivo: 18+ (lo más simple; evita el cuestionario de menores).
6. **Ficha de la tienda** (Store listing) — assets que debes preparar:
   - Icono 512×512 px (PNG). *(El actual es el logo por defecto de Flutter —
     vale la pena hacer uno propio, aunque no es bloqueante para testing.)*
   - "Feature graphic" 1024×500 px.
   - Mínimo 2 capturas de pantalla del teléfono (las del dashboard en sesión
     quedan perfectas).
   - Descripción corta (80 chars) y larga — se puede adaptar del README §2.
7. **Enviar a revisión**: la primera revisión tarda de horas a ~7 días.

## Nota sobre el tamaño del .aab

El bundle pesa ~127 MB porque el paso de "strip" de símbolos nativos
requiere el NDK de Android, que no está instalado en la máquina de
desarrollo. **No es un problema para publicar**: Play divide el bundle por
arquitectura y cada teléfono descarga solo lo suyo (~40 MB). Si quieres un
bundle más liviano: Android Studio → SDK Manager → SDK Tools → marcar
"NDK (Side by side)" → instalar → `flutter build appbundle --release`.

## Advertencia honesta

La app necesita **dos teléfonos** para hacer algo útil. En la ficha de la
tienda dilo explícitamente ("requiere dos dispositivos con la app
instalada") — los revisores de Play a veces prueban apps en un solo equipo
y conviene que la descripción explique qué van a ver.
