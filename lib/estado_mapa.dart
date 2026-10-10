import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:mapsforge_flutter_core/model.dart';

class Punto {
  final double lat;
  final double lon;
  final String? nombre;
  const Punto(this.lat, this.lon, [this.nombre]);
}

class CapaExterna {
  final String id;
  final String nombre;
  final List<List<LatLong>> lineas;
  final List<List<LatLong>> poligonos;
  bool visible;

  CapaExterna({
    required this.id,
    required this.nombre,
    required this.lineas,
    required this.poligonos,
    this.visible = true,
  });

  int get totalGeometrias => lineas.length + poligonos.length;
}

class EstadoMapa extends ChangeNotifier {
  final List<Punto> puntos = [];
  List<LatLong> trazo = const [];
  final List<CapaExterna> capasExternas = [];
  bool calculando = false;
  bool grabandoTrack = false;
  bool trackEnPausa = false;
  List<LatLong> trackActual = const [];

  List<List<LatLong>> get lineasExternasVisibles {
    return capasExternas
        .where((c) => c.visible)
        .expand((c) => c.lineas)
        .toList(growable: false);
  }

  List<List<LatLong>> get poligonosExternosVisibles {
    return capasExternas
        .where((c) => c.visible)
        .expand((c) => c.poligonos)
        .toList(growable: false);
  }

  void agregarPunto(double lat, double lon) {
    puntos.add(Punto(lat, lon));
    notifyListeners();
  }

  void quitarPunto(int indice) {
    if (indice >= 0 && indice < puntos.length) {
      puntos.removeAt(indice);
      notifyListeners();
    }
  }

  void invertirPuntos() {
    if (puntos.length < 2) return;
    puntos.replaceRange(0, puntos.length, puntos.reversed);
    notifyListeners();
  }

  void moverPuntoAInicio(int indice) {
    if (indice <= 0 || indice >= puntos.length) return;
    final p = puntos.removeAt(indice);
    puntos.insert(0, p);
    notifyListeners();
  }

  void moverPuntoAFin(int indice) {
    if (indice < 0 || indice >= puntos.length - 1) return;
    final p = puntos.removeAt(indice);
    puntos.add(p);
    notifyListeners();
  }

  void limpiar() {
    puntos.clear();
    trazo = const [];
    notifyListeners();
  }

  void agregarCapaExterna(
    String nombre,
    List<List<LatLong>> lineas,
    List<List<LatLong>> poligonos,
  ) {
    capasExternas.add(CapaExterna(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      nombre: nombre,
      lineas: lineas,
      poligonos: poligonos,
      visible: true,
    ));
    notifyListeners();
  }

  void alternarVisibilidadCapa(String id, bool visible) {
    final idx = capasExternas.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    capasExternas[idx].visible = visible;
    notifyListeners();
  }

  void eliminarCapa(String id) {
    capasExternas.removeWhere((c) => c.id == id);
    notifyListeners();
  }

  void limpiarCapasExternas() {
    capasExternas.clear();
    notifyListeners();
  }

  void iniciarTrack() {
    grabandoTrack = true;
    trackEnPausa = false;
    trackActual = const [];
    notifyListeners();
  }

  void pausarTrack() {
    if (!grabandoTrack) return;
    trackEnPausa = true;
    notifyListeners();
  }

  void reanudarTrack() {
    if (!grabandoTrack) return;
    trackEnPausa = false;
    notifyListeners();
  }

  void detenerTrack() {
    grabandoTrack = false;
    trackEnPausa = false;
    notifyListeners();
  }

  void limpiarTrack() {
    trackActual = const [];
    notifyListeners();
  }

  void agregarPuntoTrack(double lat, double lon) {
    trackActual = [...trackActual, LatLong(lat, lon)];
    notifyListeners();
  }

  void setTrazo(List<LatLong> linea) {
    trazo = linea;
    notifyListeners();
  }

  void setCalculando(bool valor) {
    calculando = valor;
    notifyListeners();
  }

  double get kilometros {
    double total = 0;
    for (var i = 0; i < trazo.length - 1; i++) {
      total += haversineKm(trazo[i].latitude, trazo[i].longitude,
          trazo[i + 1].latitude, trazo[i + 1].longitude);
    }
    return total;
  }

  double get kilometrosTrack {
    double total = 0;
    for (var i = 0; i < trackActual.length - 1; i++) {
      total += haversineKm(trackActual[i].latitude, trackActual[i].longitude,
          trackActual[i + 1].latitude, trackActual[i + 1].longitude);
    }
    return total;
  }
}

double _rad(double g) => g * math.pi / 180;

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) *
          math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.sqrt(a));
}
