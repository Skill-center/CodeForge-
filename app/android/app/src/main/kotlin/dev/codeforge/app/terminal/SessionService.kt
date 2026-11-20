package dev.codeforge.app.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import dev.codeforge.app.R
import dev.codeforge.app.runtime.RuntimeHub
import dev.codeforge.app.runtime.RuntimeHubs
import dev.codeforge.app.runtime.TerminalSession

/**
 * The foreground service that keeps terminal sessions running (Phase 5 W5;
 * docs/TERMINAL_ARCHITECTURE.md §4): it runs while any session runs, so
 * Android keeps the app's process, and with it the sessions, when the user
 * leaves the app. Its type is `specialUse`: a terminal runs for as long as
 * the user lets it, and `dataSync`'s six hours in a day would end it
 * (PHASE_5_PLAN §0). It does no work of its own.
 *
 * Its notification says how many sessions run, opens the app, and offers
 * End all, which ends every session with everything it started
 * (RuntimeHub.endAllTerminals). Without the notification permission (asked
 * at the first session on Android 13 and later, TerminalHost) it still runs,
 * and Android lists it in its task manager.
 *
 * [SessionKeeper] starts it with the first running session and stops it
 * after the last; it never starts itself again (`START_NOT_STICKY`).
 */
class SessionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val hub = RuntimeHubs.get(this)
        pending = false
        // A service started as a foreground one must be one at once, whatever
        // it then does: stopped before it is, Android 8 and 9 end the app.
        val running = hub.terminals()?.running() ?: 0
        enterForeground(running)
        current = this
        if (intent?.action == ACTION_END_ALL) {
            Log.i(TAG, "notification: End all ($running running)")
            hub.endAllTerminals { left -> Log.i(TAG, "End all from the notification: $left still running") }
        }
        Log.i(TAG, "session service started: $running running")
        // The keeper stops the service after the last session's exit. One
        // that came before the service was up left the stop to this start;
        // stopSelf(startId) leaves a newer start alone.
        if (running == 0) {
            current = null
            shown = -1
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (current === this) {
            current = null
            shown = -1
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        Log.i(TAG, "session service stopped")
        super.onDestroy()
    }

    private fun enterForeground(running: Int) {
        val notification = notification(this, running)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        shown = running
    }

    companion object {
        private const val TAG = "CodeForgeTerminal"

        // The service's state, on the main thread only (its callbacks and the
        // keeper's work run there; the tests read [active] after a wait).

        /** The running instance, from its first start until it is asked to stop. */
        @Volatile
        private var current: SessionService? = null

        /** A start was asked and has not arrived yet. */
        private var pending = false

        /** The count its notification shows; -1 with no service. */
        private var shown = -1

        /** Whether the service runs in the foreground now: between its first start and its stop. */
        val active: Boolean
            get() = current != null

        /**
         * Asks for the service with [running] sessions, or for the count in its
         * notification. Android 12 and later refuse a start from the
         * background: ForegroundServiceStartNotAllowedException, a
         * RuntimeException, is the caller's.
         */
        fun keep(context: Context, running: Int) {
            if (current == null && !pending) {
                // Its start makes the notification with the count it finds.
                context.startForegroundService(Intent(context, SessionService::class.java))
                pending = true
                Log.i(TAG, "session service asked: $running running")
            } else if (current != null && running != shown) {
                shown = running
                context.getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, notification(context, running))
            }
        }

        /**
         * Stops the service once no session runs. Only a service in the
         * foreground is stopped from outside: one started with
         * startForegroundService and stopped before it calls startForeground
         * ends the app on Android 8 and 9. A start on its way finds no session
         * and stops itself.
         */
        fun release(context: Context) {
            if (current == null) return
            current = null
            shown = -1
            context.stopService(Intent(context, SessionService::class.java))
        }

        const val CHANNEL = "terminal_sessions"
        const val NOTIFICATION_ID = 0x5E5
        const val ACTION_END_ALL = "dev.codeforge.app.action.END_ALL_TERMINALS"

        /** "2 terminal sessions running". */
        fun title(running: Int): String =
            if (running == 1) "1 terminal session running" else "$running terminal sessions running"

        /** The notification for [running] sessions; the channel is made first if need be. */
        fun notification(context: Context, running: Int): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Terminal sessions", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shows while terminal sessions run, with End all."
                        setShowBadge(false)
                    },
                )
            }
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val open = launch?.let {
                PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            val endAll = PendingIntent.getService(
                context,
                1,
                Intent(context, SessionService::class.java).setAction(ACTION_END_ALL),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val builder = Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_terminal)
                .setContentTitle(title(running))
                .setContentText("End all stops them and everything they started.")
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .addAction(Notification.Action.Builder(null as Icon?, "End all", endAll).build())
            if (open != null) builder.setContentIntent(open)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }
    }
}

/**
 * Starts [SessionService] with the first running terminal session and stops
 * it after the last, and keeps its notification's count (Phase 5 W5). Told
 * of every session's start and exit by the hub, on the sessions' delivery
 * thread; does its work on the main thread.
 */
class SessionKeeper(private val app: Context, private val hub: RuntimeHub) : (TerminalSession) -> Unit {
    private val main = Handler(Looper.getMainLooper())

    override fun invoke(session: TerminalSession) {
        main.post { update() }
    }

    private fun update() {
        val running = hub.terminals()?.running() ?: 0
        if (running == 0) {
            SessionService.release(app)
            return
        }
        try {
            SessionService.keep(app, running)
        } catch (refused: RuntimeException) {
            // Android 12 and later refuse a start from the background
            // (ForegroundServiceStartNotAllowedException); a session starts
            // from the app, so this is a stray case. The sessions run
            // regardless, and the next start or exit asks again.
            Log.w(TAG, "the session service was refused: ${refused.javaClass.simpleName}")
        }
    }

    private companion object {
        const val TAG = "CodeForgeTerminal"
    }
}
