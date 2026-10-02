import 'package:flutter_test/flutter_test.dart';
import 'package:offmaps/servicio_tracks.dart';

void main() {
  test('construirGpx crea trkpt y nombre', () {
    final servicio = ServicioTracks();
    final gpx = servicio.construirGpx(
      nombre: 'prueba',
      puntos: const [
        TrackPunto(4.6, -74.1),
        TrackPunto(4.7, -74.2),
      ],
    );

    expect(gpx, contains('<name>prueba</name>'));
    expect(gpx, contains('<trkpt lat="4.6000000" lon="-74.1000000">'));
    expect(gpx, contains('<trkpt lat="4.7000000" lon="-74.2000000">'));
    expect(gpx, contains('</gpx>'));
  });
}
