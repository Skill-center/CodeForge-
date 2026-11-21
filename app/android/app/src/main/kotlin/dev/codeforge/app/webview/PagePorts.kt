package dev.codeforge.app.webview

import android.net.Uri
import android.util.Log
import android.webkit.WebMessage
import android.webkit.WebMessagePort
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/**
 * Host → page messages through a MessagePort (Phase 5 W6,
 * docs/TERMINAL_ARCHITECTURE.md §2.2): the native half of
 * lib/services/editor/page_port.dart.
 *
 * `open` makes a message channel on a WebView (WebView.createWebMessageChannel,
 * API 23), keeps one end, and posts the other to the page loaded in it
 * (WebView.postWebMessage), for the page's origin only: Android delivers it
 * to the main frame only if that frame has the origin. The page takes the
 * port (editor/src/terminal/hostport.ts) and says so in its ready
 * announcement, and from then on `post` hands each host message to the port
 * rather than the Dart side running one script per message, which the page
 * had to parse and compile. The page validates whatever arrives either way.
 *
 * The WebView comes from webview_flutter_android's public native API, by the
 * identifier its Dart side gives (AndroidWebViewController.webViewIdentifier);
 * a plugin of the app's own, added by MainActivity, holds the binding it
 * takes. One port per WebView: a new `open` closes the one before (a page
 * load replaced the page that held it).
 */
class PagePorts : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var channel: MethodChannel? = null
    private val ports = HashMap<Long, WebMessagePort>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pluginBinding = binding
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        for (port in ports.values) port.close()
        ports.clear()
        pluginBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val webView = (call.argument<Any>("webView") as? Number)?.toLong()
        if (webView == null) {
            result.error("bad_arguments", "${call.method} needs webView", null)
            return
        }
        when (call.method) {
            "open" -> result.success(open(webView, call.argument<String>("origin")))
            "post" -> post(webView, call.argument<String>("message"), result)
            "close" -> {
                ports.remove(webView)?.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun open(identifier: Long, origin: String?): Boolean {
        val binding = pluginBinding ?: return false
        if (origin == null || !ORIGIN.matches(origin)) return false
        val webView = WebViewFlutterAndroidExternalApi.getWebView(binding, identifier) ?: return false
        ports.remove(identifier)?.close()
        return try {
            val pair = webView.createWebMessageChannel()
            ports[identifier] = pair[0]
            webView.postWebMessage(WebMessage(HELLO, arrayOf(pair[1])), Uri.parse(origin))
            true
        } catch (error: RuntimeException) {
            ports.remove(identifier)?.close()
            Log.w(TAG, "no port for the page: $error")
            false
        }
    }

    private fun post(identifier: Long, message: String?, result: MethodChannel.Result) {
        val port = ports[identifier]
        when {
            message == null -> result.error("bad_arguments", "post needs message", null)
            port == null -> result.error("no_port", "The page has no port.", null)
            else -> try {
                port.postMessage(WebMessage(message))
                result.success(null)
            } catch (error: RuntimeException) {
                result.error("post_failed", error.toString(), null)
            }
        }
    }

    companion object {
        const val CHANNEL = "dev.codeforge/page_port"

        /** The port's message: editor/src/terminal/hostport.ts's HOST_PORT_HELLO. */
        const val HELLO = "codeforge-host-port"

        private const val TAG = "CodeForgePagePort"

        /** An https origin: scheme and host, nothing else (the pages' own). */
        private val ORIGIN = Regex("https://[a-z0-9.-]+")
    }
}
