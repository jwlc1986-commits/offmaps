package com.example.offmaps

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import btools.routingapp.IBRouterService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val canal = "offmaps/nativo"
    private val paqueteBrouter = "btools.routingapp"
    private val ejecutor = Executors.newSingleThreadExecutor()
    private val hiloPrincipal = Handler(Looper.getMainLooper())

    private var canalFlutter: MethodChannel? = null
    private var brouter: IBRouterService? = null
    private var pendiente: Map<String, Any>? = null
    private var resultadoConexion: MethodChannel.Result? = null
    private var resultadoPermisoNotificaciones: MethodChannel.Result? = null
    private var resultadoPermisoUbicacionFondo: MethodChannel.Result? = null

    private val reqNotificaciones = 4101
    private val reqUbicacionFondo = 4102

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        canalFlutter = MethodChannel(engine.dartExecutor.binaryMessenger, canal)
        canalFlutter?.setMethodCallHandler { call, result ->
            when (call.method) {
                "brouterInstalado" -> result.success(brouterInstalado())
                "conectarBrouter" -> conectarBrouter(result)
                "calcularRuta" -> {
                    val lonlats = call.argument<String>("lonlats") ?: ""
                    val perfil = call.argument<String>("perfil") ?: "trekking"
                    calcularRuta(lonlats, perfil, result)
                }
                "listarMapas" -> result.success(listarMapas())
                "permisoAlmacenamiento" -> permisoAlmacenamiento(result)
                "permisoNotificaciones" -> permisoNotificaciones(result)
                "permisoUbicacionFondo" -> permisoUbicacionFondo(result)
                "obtenerPendiente" -> {
                    result.success(pendiente)
                    pendiente = null
                }
                else -> result.notImplemented()
            }
        }
        procesarIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val concedido = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        when (requestCode) {
            reqNotificaciones -> {
                resultadoPermisoNotificaciones?.success(concedido)
                resultadoPermisoNotificaciones = null
            }
            reqUbicacionFondo -> {
                resultadoPermisoUbicacionFondo?.success(concedido)
                resultadoPermisoUbicacionFondo = null
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        procesarIntent(intent)
    }

    // ---------------------------------------------------------------- BRouter

    private fun brouterInstalado(): Boolean = try {
        packageManager.getPackageInfo(paqueteBrouter, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun conectarBrouter(result: MethodChannel.Result) {
        if (brouter != null) { result.success(true); return }
        if (!brouterInstalado()) { result.success(false); return }
        if (resultadoConexion != null) { result.success(false); return } // ya hay una conexión en curso
        val conexion = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, servicio: IBinder?) {
                brouter = IBRouterService.Stub.asInterface(servicio)
                resultadoConexion?.success(true)
                resultadoConexion = null
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                brouter = null
            }
        }
        val intent = Intent().setClassName(paqueteBrouter, "$paqueteBrouter.BRouterService")
        resultadoConexion = result
        val ok = try { bindService(intent, conexion, Context.BIND_AUTO_CREATE) } catch (e: Exception) { false }
        if (!ok) {
            resultadoConexion = null
            result.success(false)
        }
    }

    private fun calcularRuta(lonlats: String, perfil: String, result: MethodChannel.Result) {
        val servicio = brouter
        if (servicio == null) {
            result.error("BROUTER_NO_CONECTADO", "Conecta con BRouter primero", null)
            return
        }
        ejecutor.execute {
            var gpx: String? = null
            var error: String? = null
            try {
                val params = Bundle().apply {
                    putString("lonlats", lonlats)
                    putString("profile", perfil)
                    putString("trackFormat", "gpx")
                }
                gpx = servicio.getTrackFromParams(params)
                if (gpx == null || !gpx.startsWith("<")) {
                    error = gpx ?: "sin respuesta de BRouter"
                }
            } catch (e: Exception) {
                error = e.message ?: "error calculando la ruta"
            }
            hiloPrincipal.post {
                if (error != null) result.error("BROUTER", error, null)
                else result.success(gpx)
            }
        }
    }

    // ------------------------------------------------------------- Almacenamiento

    private fun listarMapas(): List<String> {
        val carpeta = File(Environment.getExternalStorageDirectory(), "OffMaps")
        if (!carpeta.exists()) return emptyList()
        return carpeta.listFiles { f -> f.isFile && f.name.endsWith(".map", true) }
            ?.map { it.absolutePath } ?: emptyList()
    }

    private fun permisoAlmacenamiento(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
            result.success(false)
        } else {
            result.success(true)
        }
    }

    private fun permisoNotificaciones(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (resultadoPermisoNotificaciones != null) {
            result.success(false)
            return
        }
        resultadoPermisoNotificaciones = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), reqNotificaciones)
    }

    private fun permisoUbicacionFondo(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (resultadoPermisoUbicacionFondo != null) {
            result.success(false)
            return
        }
        resultadoPermisoUbicacionFondo = result
        requestPermissions(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), reqUbicacionFondo)
    }

    // ------------------------------------------------- Coordenadas desde otras apps

    private fun procesarIntent(intent: Intent?) {
        intent ?: return
        var lat: Double? = null
        var lon: Double? = null

        if (intent.action == Intent.ACTION_VIEW) {
            val datos = intent.data
            if (datos != null && datos.scheme.equals("geo", true)) {
                val par = parsearGeo(datos)
                lat = par?.first
                lon = par?.second
            }
        } else if (intent.action == Intent.ACTION_SEND) {
            val texto = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
            val par = parsearTexto(texto)
            lat = par?.first
            lon = par?.second
        }

        if (lat != null && lon != null) {
            val datos = mapOf("lat" to lat, "lon" to lon, "origen" to (intent.action ?: ""))
            pendiente = datos
            try {
                canalFlutter?.invokeMethod("coordenadaEntrante", datos)
            } catch (e: Exception) {
                // Dart aún no está listo; queda en pendiente
            }
        }
    }

    private fun parsearGeo(uri: Uri): Pair<Double, Double>? {
        val ssp = uri.schemeSpecificPart ?: return null
        val coords = ssp.substringBefore('?').substringBefore('&')
        Regex("^(-?\\d{1,2}(\\.\\d+)?),(-?\\d{1,3}(\\.\\d+)?)$").find(coords)?.let {
            return Pair(it.groupValues[1].toDouble(), it.groupValues[3].toDouble())
        }
        val q = uri.getQueryParameter("q") ?: return null
        return parsearTexto(q)
    }

    private fun parsearTexto(texto: String): Pair<Double, Double>? {
        val m = Regex("(-?\\d{1,3}(?:\\.\\d+)?)[ ,;/]+(-?\\d{1,3}(?:\\.\\d+)?)").find(texto) ?: return null
        val a = m.groupValues[1].toDouble()
        val b = m.groupValues[2].toDouble()
        return if (a < -90 || a > 90) Pair(b, a) else Pair(a, b)
    }
}
