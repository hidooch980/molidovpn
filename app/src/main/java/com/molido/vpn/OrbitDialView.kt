package com.molido.vpn

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.text.TextPaint
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The MolidoVPN connect control: a rounded-square "squircle" with a gradient
 * ring (accent -> connected), a soft glow that pulses while connecting, and a
 * power glyph + caption (or the session timer) inside.
 *
 * Sizing machinery ([sizeScale], [RING_DP] + [BLEED_DP] measured box) is kept
 * from the original dial so the console fit logic in MainActivity is unchanged;
 * the squircle is drawn at [SQUIRCLE_HALF_DP] inside that box, leaving the glow
 * room to spread without being clipped by the software layer.
 */
class OrbitDialView(
    context: Context,
    private var palette: AppAppearance.Palette,
) : View(context) {

    enum class State { DISCONNECTED, CONNECTING, CONNECTED, DEGRADED, FAILED }

    var state: State = State.DISCONNECTED
        set(value) {
            val previous = field
            field = value
            contentDescription = when (value) {
                State.DISCONNECTED, State.FAILED -> "اتصال"
                State.CONNECTING -> "در حال اتصال"
                State.CONNECTED, State.DEGRADED -> "قطع اتصال"
            }
            if (value == State.CONNECTED || value == State.DEGRADED) {
                if (previous != State.CONNECTED && previous != State.DEGRADED) tickReveal = 0f
                animateTickReveal()
            } else {
                tickReveal = 0f
            }
            if (value == State.CONNECTING || value == State.CONNECTED || value == State.DEGRADED) {
                startLoop()
            } else {
                stopLoop()
            }
            invalidate()
        }

    /** Session uptime text drawn inside the core. Empty hides it. */
    var timerText: String = ""
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    /**
     * Connect progress, 0..100, or -1 for "no measurable progress".
     *
     * Only drawn in [State.CONNECTING], and only when non-negative: a transport
     * that cannot report real progress shows the spinner alone rather than a
     * fabricated number. See MolidoVpnService.EXTRA_PROGRESS.
     */
    var progressPercent: Int = -1
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    // The dial is hand-drawn glass, so it needs the same lighting model as the
    // card backgrounds: white speculars over a dark canvas, dark speculars over
    // a light one. Read once — the palette cannot change without recreate().
    private val light = Sculpt.lighting
    private val density = resources.displayMetrics.density
    private val bounds = RectF()
    private val corePath = Path()

    private var loopFraction = 0f
    private var pulse = 0f
    private var tickReveal = 0f
    private var loopAnimator: ValueAnimator? = null
    private var tickAnimator: ValueAnimator? = null

    private val monoTypeface: Typeface = Typefaces.mono(context)
    private val labelTypeface: Typeface
        get() = Typefaces.medium(context)

    init {
        isClickable = true
        isFocusable = true
        isFocusableInTouchMode = false
        contentDescription = "اتصال"
        // Shadow layers and sweep gradients need software rendering to be exact
        // on older GPUs; the view is small and repaints at most 20fps.
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun applyPalette(next: AppAppearance.Palette) {
        palette = next
        invalidate()
    }

    private fun accentFor(state: State): Int = when (state) {
        State.DISCONNECTED -> palette.muted
        State.CONNECTING -> palette.amber
        State.CONNECTED -> palette.connected
        State.DEGRADED -> palette.amber
        State.FAILED -> palette.danger
    }

    /**
     * Uniform shrink factor for the whole dial, bleed included.
     *
     * The console asks for this when its natural height would overflow the
     * viewport: shrinking the dial is how the screen stops scrolling. Because
     * the factor scales the measured box AND the ring together, the ratio
     * between them is untouched, so the halo and ripples keep exactly the
     * proportional room they have at 1.0 and cannot be cropped by shrinking.
     */
    var sizeScale: Float = 1f
        set(value) {
            val clamped = value.coerceIn(MIN_SIZE_SCALE, 1f)
            if (field != clamped) {
                field = clamped
                requestLayout()
            }
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // The measured box is the RING plus [BLEED_DP], not the ring alone.
        //
        // This is the actual cause of the dial having been cropped on all four
        // sides, and clipChildren=false on the ancestors could never have fixed
        // it: this view runs with LAYER_TYPE_SOFTWARE, so Android allocates an
        // offscreen bitmap exactly the size of the VIEW and every pixel outside
        // it is discarded before any parent gets a say. The halo reaches
        // HALO_OUTSET+HALO_PULSE past the ring and a ripple reaches
        // ring*RIPPLE_GROWTH past it, in every direction — with a box of exactly
        // 2*ring all of that got shaved flat.
        //
        // So the canvas is always ring + bleed, and BLEED_DP is derived from
        // those two reaches rather than guessed. Shrinking goes through
        // [sizeScale], which scales box and ring by the same factor, so the
        // bleed can never be squeezed out from under the glow.
        val desired = dp(((RING_DP + BLEED_DP) * 2 * sizeScale).roundToInt())
        val size = resolveSize(desired, widthMeasureSpec)
            .coerceAtMost(resolveSize(desired, heightMeasureSpec))
        // Always square: a non-square canvas would put the ring off-centre.
        setMeasuredDimension(size, size)
    }

    private val ringRect = RectF()
    private val glowRect = RectF()
    private val ringMatrix = Matrix()

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f
        val cy = height / 2f
        val half = minOf(width, height) / 2f
        // Same shrink/safety maths as the old dial: never larger than the box
        // leaves room for the glow.
        val ring = minOf(
            dp(RING_DP) * sizeScale,
            half * RING_DP / (RING_DP + BLEED_DP).toFloat(),
        )
        val geo = ring / dp(RING_DP)
        val active = state == State.CONNECTED || state == State.DEGRADED
        val side = dp(SQUIRCLE_HALF_DP) * geo
        val corner = dp(SQUIRCLE_CORNER_DP) * geo
        bounds.set(cx - side, cy - side, cx + side, cy + side)

        drawGlow(canvas, corner, active, geo)
        drawBody(canvas, corner)
        drawGradientRing(canvas, cx, cy, corner, geo)
        drawContents(canvas, cx, cy, active, geo)
        if (isFocused) {
            paint.style = Paint.Style.STROKE
            paint.shader = null
            paint.strokeWidth = 2f * density
            paint.color = palette.primary
            val o = dp(6).toFloat()
            glowRect.set(bounds.left - o, bounds.top - o, bounds.right + o, bounds.bottom + o)
            canvas.drawRoundRect(glowRect, corner + o, corner + o, paint)
        }
    }

    /** Soft coloured glow around the squircle; breathes on [pulse] while connecting. */
    private fun drawGlow(canvas: Canvas, corner: Float, active: Boolean, geo: Float) {
        val color: Int
        val alpha: Float
        val blurDp: Float
        when {
            state == State.CONNECTING -> {
                color = palette.amber; alpha = 0.28f + 0.40f * pulse; blurDp = (16f + 14f * pulse) * geo
            }
            active -> {
                color = palette.connected; alpha = 0.30f + 0.10f * pulse; blurDp = 22f * geo
            }
            state == State.FAILED -> {
                color = palette.danger; alpha = 0.24f; blurDp = 14f * geo
            }
            else -> {
                color = palette.primary; alpha = 0.16f; blurDp = 14f * geo
            }
        }
        paint.style = Paint.Style.FILL
        paint.shader = null
        paint.color = palette.surface
        paint.setShadowLayer(blurDp * density, 0f, 0f, Sculpt.withAlpha(color, alpha))
        canvas.drawRoundRect(bounds, corner, corner, paint)
        paint.clearShadowLayer()
    }

    private fun drawBody(canvas: Canvas, corner: Float) {
        paint.style = Paint.Style.FILL
        paint.shader = LinearGradient(
            0f, bounds.top, 0f, bounds.bottom,
            palette.surfaceVariant, palette.surface,
            Shader.TileMode.CLAMP,
        )
        canvas.drawRoundRect(bounds, corner, corner, paint)
        paint.shader = null
    }

    /** accent -> connected sweep around the squircle; rotates while connecting. */
    private fun drawGradientRing(canvas: Canvas, cx: Float, cy: Float, corner: Float, geo: Float) {
        val stroke = 4f * density * geo
        val inset = stroke / 2f
        ringRect.set(bounds.left + inset, bounds.top + inset, bounds.right - inset, bounds.bottom - inset)
        val start: Int
        val end: Int
        when (state) {
            State.FAILED -> { start = palette.danger; end = Sculpt.blend(palette.danger, palette.amber, 0.35f) }
            State.CONNECTING -> { start = palette.amber; end = palette.primary }
            State.DEGRADED -> { start = palette.amber; end = palette.connected }
            else -> { start = palette.primary; end = palette.connected }
        }
        val alpha = if (state == State.DISCONNECTED) 0.60f else 1f
        val shader = SweepGradient(
            cx, cy,
            intArrayOf(
                Sculpt.withAlpha(start, alpha),
                Sculpt.withAlpha(end, alpha),
                Sculpt.withAlpha(start, alpha),
            ),
            floatArrayOf(0f, 0.5f, 1f),
        )
        if (state == State.CONNECTING) {
            ringMatrix.reset()
            ringMatrix.setRotate(loopFraction * 360f, cx, cy)
            shader.setLocalMatrix(ringMatrix)
        }
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = stroke
        paint.shader = shader
        canvas.drawRoundRect(ringRect, corner - inset, corner - inset, paint)
        paint.shader = null
    }

    /** Power glyph + caption, or the session timer while the tunnel is up. */
    private fun drawContents(canvas: Canvas, cx: Float, cy: Float, active: Boolean, geo: Float) {
        val iconColor = when (state) {
            State.CONNECTED -> palette.connected
            State.DEGRADED, State.CONNECTING -> palette.amber
            State.FAILED -> palette.danger
            State.DISCONNECTED -> palette.primary
        }
        val iconCy = cy - dp(18) * geo
        val r = dp(22) * geo
        paint.style = Paint.Style.STROKE
        paint.shader = null
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeWidth = 3.2f * density * geo
        paint.color = if (state == State.CONNECTING) {
            Sculpt.withAlpha(iconColor, 0.55f + 0.45f * pulse)
        } else {
            iconColor
        }
        ringRect.set(cx - r, iconCy - r, cx + r, iconCy + r)
        // 300 degree arc with the gap centred on straight up.
        canvas.drawArc(ringRect, -60f, 300f, false, paint)
        canvas.drawLine(cx, iconCy - r - dp(3) * geo, cx, iconCy - r * 0.05f, paint)
        paint.strokeCap = Paint.Cap.BUTT

        textPaint.textAlign = Paint.Align.CENTER
        textPaint.letterSpacing = spacing(0.12f)
        if (active && timerText.isNotEmpty()) {
            textPaint.typeface = monoTypeface
            textPaint.textSize = 22f * density * geo
            textPaint.color = palette.ink
            canvas.drawText(timerText, cx, cy + dp(34) * geo, textPaint)
            textPaint.typeface = labelTypeface
            textPaint.textSize = 9.5f * density * geo
            textPaint.color = palette.muted
            canvas.drawText(Strings.t("SESSION"), cx, cy + dp(52) * geo, textPaint)
        } else {
            textPaint.typeface = labelTypeface
            textPaint.textSize = 12f * density * geo
            textPaint.color = when (state) {
                State.FAILED -> palette.dangerText
                State.CONNECTING -> palette.amberText
                else -> palette.muted
            }
            val caption = when (state) {
                State.CONNECTING -> if (progressPercent >= 0) {
                    Strings.tf("CONNECTING %s%%", progressPercent)
                } else {
                    Strings.t("CONNECTING")
                }
                State.FAILED -> Strings.t("RETRY")
                State.CONNECTED, State.DEGRADED -> Strings.t("Connected")
                State.DISCONNECTED -> Strings.t("TAP TO CONNECT")
            }
            canvas.drawText(caption, cx, cy + dp(40) * geo, textPaint)
        }
        textPaint.letterSpacing = 0f
    }

    override fun onTouchEvent(event: MotionEvent): Boolean = when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
            animate().scaleX(0.965f).scaleY(0.965f).setDuration(110).start()
            true
        }
        MotionEvent.ACTION_UP -> {
            animate().scaleX(1f).scaleY(1f).setDuration(190).start()
            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            performClick()
            true
        }
        MotionEvent.ACTION_CANCEL -> {
            animate().scaleX(1f).scaleY(1f).setDuration(190).start()
            true
        }
        else -> super.onTouchEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            performClick()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: android.graphics.Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        invalidate()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // A view can be detached mid-connection (screen off, returning from
        // Recents) and reattached still CONNECTED. Without this the halo and
        // sheen stay frozen.
        if (state == State.CONNECTING || state == State.CONNECTED || state == State.DEGRADED) startLoop()
    }

    override fun onDetachedFromWindow() {
        stopLoop()
        tickAnimator?.cancel()
        tickAnimator = null
        super.onDetachedFromWindow()
    }

    private fun startLoop() {
        if (loopAnimator != null) return
        // Respect the system animator scale / 'remove animations': no loop, a
        // static half-glow instead.
        if (!ValueAnimator.areAnimatorsEnabled()) {
            pulse = 0.5f
            invalidate()
            return
        }
        loopAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = if (state == State.CONNECTING) 1_150 else 4_400
            repeatCount = ValueAnimator.INFINITE
            interpolator = null
            addUpdateListener {
                loopFraction = it.animatedFraction
                pulse = if (loopFraction < 0.5f) loopFraction * 2f else (1f - loopFraction) * 2f
                invalidate()
            }
            start()
        }
    }

    private fun stopLoop() {
        loopAnimator?.cancel()
        loopAnimator = null
        loopFraction = 0f
        pulse = 0f
    }

    private fun animateTickReveal() {
        tickAnimator?.cancel()
        tickAnimator = ValueAnimator.ofFloat(tickReveal, 1f).apply {
            duration = 900
            addUpdateListener {
                tickReveal = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun dp(value: Int): Int = (value * density).roundToInt()

    companion object {
        const val TICK_COUNT = 60
        /** Ticks lit when connected — 44 of 60, as in the mock. */
        const val TICK_LIT = 44
        /** How far a ripple grows past the ring (mock: scale(1) → scale(1.32)). */
        const val RIPPLE_GROWTH = 0.32f
        /**
         * Ring radius in dp.
         *
         * The mock drew a 266dp box (r = 133dp). That made the whole console
         * 840dp tall on a 1080x2400 phone, ~70dp more than the viewport, so the
         * main screen scrolled and part of the action bar sat below the fold.
         * 112dp is the largest ring that lets the full column fit without
         * scrolling while keeping the dial the dominant element on the screen.
         */
        const val RING_DP = 112
        /** How far past the ring the halo's outer edge sits, at rest. */
        const val HALO_OUTSET_DP = 24
        /** Extra reach the halo gains at the top of its breath. */
        const val HALO_PULSE_DP = 7
        /**
         * Slack so a feathered edge or a stroke's outer half never lands on the
         * last row of pixels. 4dp covers the ripple's 1.5px stroke and the
         * tick shadow at any density.
         */
        const val BLEED_MARGIN_DP = 4
        /**
         * Extra radius the view is measured with, beyond the ring, so the layers
         * that deliberately paint outside the ring have canvas to land on.
         *
         * DERIVED, not hand-tuned: this used to be a magic 46 that had to be
         * re-checked by hand every time the ring changed, and getting it wrong is
         * exactly what shaved the glow flat on all four sides. Now it is computed
         * from the two things that actually paint outside the ring —
         *
         *   - a ripple, reaching ring * RIPPLE_GROWTH past the ring
         *   - the halo, reaching HALO_OUTSET + HALO_PULSE past the ring
         *
         * — so changing RING_DP alone can never crop the dial again.
         */
        val BLEED_DP: Int = ceil(
            maxOf(RING_DP * RIPPLE_GROWTH, (HALO_OUTSET_DP + HALO_PULSE_DP).toFloat())
        ).toInt() + BLEED_MARGIN_DP
        /**
         * Floor for [sizeScale]. Below this the dial stops reading as the primary
         * control, so a screen too short even for the shrunk dial is allowed to
         * scroll instead — scrolling is recoverable, an unreachable connect
         * button is not.
         */
        const val MIN_SIZE_SCALE = 0.78f
        /** Half the squircle's side at sizeScale 1 (190dp control). */
        const val SQUIRCLE_HALF_DP = 95
        /** Squircle corner radius at sizeScale 1. */
        const val SQUIRCLE_CORNER_DP = 64
        /** Core radius as a fraction of the ring: 99dp core / 133dp ring. */
        const val CORE_RATIO = 0.744f
        /**
         * 2π as a float.
         *
         * A literal rather than `(Math.PI * 2).toFloat()`: `const val` needs a
         * compile-time constant, and a Java static field is not one.
         */
        private const val TWO_PI = 6.2831855f
        /**
         * Lobes in the CONNECTING standing wave.
         *
         * Three is deliberate: one lobe is a spinner, two reads as a propeller,
         * and four or more makes the 60-tick gauge look like it is flickering
         * because each crest gets too few ticks to resolve.
         */
        private const val WAVE_LOBES = 3f
        /**
         * Exponent applied to the rectified sine.
         *
         * A raw sine leaves the whole rim at half brightness, which is exactly
         * the flat pale glow this replaces. 2.4 pulls the troughs down to the
         * resting tick colour and keeps the crests compact.
         */
        private const val WAVE_SHARPNESS = 2.4
    }
}

/** Neon letter-spacing scatters Persian's joined letters — clamp for Persian. */
private fun spacing(v: Float): Float = if (AppLanguage.current() != "en") 0f else v
