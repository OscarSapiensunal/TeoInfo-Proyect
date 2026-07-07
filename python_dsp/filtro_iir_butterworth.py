"""
Diseño y análisis de un filtro IIR Butterworth práctico.
Teoría de la Información y Sistemas de Comunicación — UNAL (Capítulo II).
"""
from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import signal
import matplotlib.pyplot as plt


def disenar_filtro_iir(
    tipo: str,
    orden: int,
    frec_corte: float | tuple[float, float],
    fs: float,
) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """Diseña un filtro IIR Butterworth y devuelve los coeficientes (b, a) de la función de transferencia."""
    b, a = signal.butter(orden, frec_corte, btype=tipo, fs=fs)
    return b, a


def generar_senal_prueba(
    fs: float,
    duracion: float,
    f_fundamental: float = 5.0,
    f_ruido: float = 200.0,
    amp_ruido: float = 0.5,
) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """Genera una señal simétrica: componente fundamental continua + ruido de alta frecuencia."""
    n_muestras = int(fs * duracion)
    t = np.linspace(0, duracion, n_muestras, endpoint=False)
    fundamental = np.sin(2 * np.pi * f_fundamental * t)
    ruido_alta_frec = amp_ruido * np.sin(2 * np.pi * f_ruido * t)
    senal = fundamental + ruido_alta_frec
    return t, senal


def aplicar_filtro(
    b: NDArray[np.float64],
    a: NDArray[np.float64],
    senal: NDArray[np.float64],
) -> NDArray[np.float64]:
    """Aplica el filtro con procesamiento hacia adelante y hacia atrás (filtfilt) → fase cero."""
    return signal.filtfilt(b, a, senal)


def graficar_resultados(
    b: NDArray[np.float64],
    a: NDArray[np.float64],
    fs: float,
    t: NDArray[np.float64],
    senal_original: NDArray[np.float64],
    senal_filtrada: NDArray[np.float64],
) -> None:
    """Grafica en un solo layout: Bode de magnitud y comparación temporal original vs. filtrada."""
    w, h = signal.freqz(b, a, worN=2048, fs=fs)
    magnitud_db = 20 * np.log10(np.abs(h) + 1e-12)

    fig, (ax_bode, ax_tiempo) = plt.subplots(2, 1, figsize=(10, 8))

    ax_bode.plot(w, magnitud_db, color="tab:blue")
    ax_bode.set_title("Diagrama de Bode — Magnitud (Filtro Butterworth)")
    ax_bode.set_xlabel("Frecuencia [Hz]")
    ax_bode.set_ylabel("Magnitud [dB]")
    ax_bode.grid(True, which="both")

    ax_tiempo.plot(t, senal_original, label="Original", color="tab:gray", alpha=0.6)
    ax_tiempo.plot(t, senal_filtrada, label="Filtrada", color="tab:red", linewidth=1.8)
    ax_tiempo.set_title("Señal en el dominio del tiempo: original vs. filtrada")
    ax_tiempo.set_xlabel("Tiempo [s]")
    ax_tiempo.set_ylabel("Amplitud")
    ax_tiempo.legend()
    ax_tiempo.grid(True)

    fig.tight_layout()
    plt.show()


def main() -> None:
    fs: float = 2000.0
    orden: int = 4
    frec_corte: float = 30.0
    tipo: str = "lowpass"
    duracion: float = 1.0

    b, a = disenar_filtro_iir(tipo, orden, frec_corte, fs)
    t, senal = generar_senal_prueba(fs, duracion, f_fundamental=5.0, f_ruido=200.0)
    senal_filtrada = aplicar_filtro(b, a, senal)
    graficar_resultados(b, a, fs, t, senal, senal_filtrada)


if __name__ == "__main__":
    main()

# La fase de un filtro IIR práctico no es lineal porque su retardo de grupo depende de la
# frecuencia (consecuencia de los polos en el plano-Z), a diferencia del filtro ideal de fase
# lineal. Esto dispersa temporalmente las componentes de la señal; por eso se usa filtfilt.
