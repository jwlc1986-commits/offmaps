import 'package:flutter_test/flutter_test.dart';
import 'package:offmaps/servicio_importacion.dart';

void main() {
  final servicio = ServicioImportacion();

  test('parsear GPX extrae trkseg y rte', () {
    const gpx = '''
<gpx>
  <trk><trkseg>
    <trkpt lat="4.6" lon="-74.1"/>
    <trkpt lat="4.7" lon="-74.2"/>
  </trkseg></trk>
  <rte>
    <rtept lat="4.8" lon="-74.3"/>
    <rtept lat="4.9" lon="-74.4"/>
  </rte>
</gpx>
''';
    final capa = servicio.parsearGpxTexto(nombre: 'demo.gpx', texto: gpx);
    expect(capa.lineas.length, 2);
    expect(capa.poligonos, isEmpty);
  });

  test('parsear KML extrae línea y polígono', () {
    const kml = '''
<kml><Document>
  <Placemark><LineString><coordinates>
    -74.1,4.6,0 -74.2,4.7,0
  </coordinates></LineString></Placemark>
  <Placemark><Polygon><outerBoundaryIs><LinearRing><coordinates>
    -74.0,4.0,0 -74.1,4.0,0 -74.1,4.1,0 -74.0,4.1,0
  </coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
</Document></kml>
''';
    final capa = servicio.parsearKmlTexto(nombre: 'demo.kml', texto: kml);
    expect(capa.lineas.length, 1);
    expect(capa.poligonos.length, 1);
    expect(capa.poligonos.first.length, greaterThanOrEqualTo(5));
  });
}
