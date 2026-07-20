# Política de Privacidad — DSP BT Analyzer

**Última actualización:** 19 de julio de 2026

**DSP BT Analyzer** es una aplicación académica desarrollada para el curso
"Teoría de la Información y Sistemas de Comunicación" de la Universidad
Nacional de Colombia. Permite la comunicación de voz punto a punto entre dos
teléfonos mediante Bluetooth Clásico, con análisis de señales en tiempo real.

## Datos que la aplicación NO recolecta

- **No** recolecta, almacena ni transmite datos personales a ningún servidor.
- **No** tiene conexión a internet: toda la comunicación ocurre directamente
  entre los dos teléfonos emparejados por Bluetooth.
- **No** usa servicios de analítica, publicidad ni rastreo de ningún tipo.
- **No** guarda grabaciones: el audio se transmite en vivo y no se escribe en
  el almacenamiento del dispositivo.

## Permisos que solicita y por qué

| Permiso | Uso |
|---|---|
| **Micrófono** (`RECORD_AUDIO`) | Capturar la voz que se transmite en vivo al otro teléfono. El audio nunca se guarda ni sale de los dos dispositivos conectados. |
| **Bluetooth** (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`) | Descubrir, emparejar y conectar los dos teléfonos que participan en la sesión de voz. |
| **Ubicación** (`ACCESS_FINE_LOCATION`) | Requisito del sistema Android 11 o inferior para poder escanear dispositivos Bluetooth cercanos. La aplicación no consulta ni usa la posición geográfica. |
| **Archivos de audio** (`READ_MEDIA_AUDIO`) | Solo en el "modo laboratorio" opcional: seleccionar un archivo .wav local como señal de prueba. |

## Contacto

Para cualquier consulta sobre esta política:
**osaavedra@unal.edu.co**
