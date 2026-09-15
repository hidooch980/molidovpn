package com.molido.vpn

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * Reusable Orbit surfaces. Everything here is deliberately view-based and hand
 * built: the app ships no Compose runtime and no Material components, and a 49MB
 * APK is already mostly native libraries.
 */

private fun Context.px(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

private fun Context.orbitLabel(
    text: String,
    size: Float,
    color: Int,
    medium: Boolean = false,
    mono: Boolean = false,
    spacing: Float = 0f,
): TextView = TextView(this).apply {
    this.text = text
    textSize = size
    setTextColor(color)
    letterSpacing = if (AppLanguage.current() != "en") 0f else spacing
    typeface = when {
        mono -> Typefaces.mono(context)
        medium -> Typefaces.medium(context)
        else -> Typefaces.regular(context)
    }
    if (AppLanguage.current() != "en") {
        setLineSpacing(0f, Typefaces.lineHeightMult())
    }
}

/**
 * One at-a-glance counter with a sparkline floor.
 *
 * Each tile owns its own accent — mint for DOWN, violet for UP, amber for SPEED,
 * exactly as the approved mock. All three used to share `palette.primary`, which
 * is why every bar row looked identical and flat. The caption takes the accent
 * too, and the bars fade from the accent to a neighbouring hue across the row.
 */
class MetricTile(
    context: Context,
    private val palette: AppAppearance.Palette,
    keyText: String,
    private val accent: Int,
    private val accentSecondary: Int = accent,
    /**
     * The readable sibling of [accent], used for the key label only.
     *
     * Defaults to [accent] so the dark palette and any existing call site are
     * unchanged; the light palette passes a darkened value.
     */
    private val accentText: Int = accent,
    onClick: () -> Unit,
) : LinearLayout(context) {

    private val valueView: TextView
    private val unitView: TextView
    private val bars: MicroBarsView

    init {
        orientation = VERTICAL
        val fill = Sculpt.blend(palette.surface, palette.ink, 0.03f)
        background = Sculpt.sculptedRipple(
            resources.displayMetrics.density, fill, 20, accent,
            accent = Sculpt.withAlpha(accent, 0.18f),
        )
        setPadding(context.px(13), context.px(11), context.px(13), 0)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }

        // Caption in the tile's own accent: the mock coloured .k per tile.
        // accentText, not accent: this is 8.5sp bold lettering, the strictest
        // contrast case in the app. On the light palette the vivid accent sits at
        // 3.4:1 (fine for the bars below, not for letters); accentText is 6:1.
        // The sparkline keeps `accent`, which is where the colour identity lives.
        addView(context.orbitLabel(keyText, 8.5f, Sculpt.withAlpha(accentText, 0.92f), medium = true, spacing = 0.13f))

        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.BOTTOM
        }
        valueView = context.orbitLabel("0", 21f, palette.ink, medium = true, mono = true)
        unitView = context.orbitLabel("B", 9f, Sculpt.withAlpha(palette.faint, 0.95f), medium = true, spacing = 0.08f)
        row.addView(valueView)
        row.addView(unitView, LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { leftMargin = context.px(3); bottomMargin = context.px(3) })
        addView(row, LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = context.px(1) })

        bars = MicroBarsView(context, accent, accentSecondary).apply { seed() }
        addView(bars, LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            context.px(16),
        ).apply { topMargin = context.px(5); bottomMargin = context.px(9) })
    }

    /** [value] is pre-scaled for display; [unit] is its suffix, e.g. "GB". */
    fun setValue(value: String, unit: String) {
        valueView.text = value
        unitView.text = unit
    }

    fun push(sample: Float) = bars.push(sample)

    fun resetBars() = bars.reset()

    fun dim(active: Boolean) {
        alpha = if (active) 1f else 0.55f
    }
}

/**
 * Segmented transport picker with a lit thumb that slides between cells.
 *
 * The thumb is a sibling view positioned by translation rather than a background
 * on the selected cell, so the movement is animatable and the cells stay dumb
 * text views. Each cell also gets its own sculpted press state — tapping
 * WireGuard used to give no visual feedback at all because the cells were bare
 * TextViews with no background.
 *
 * ## Why it grids instead of staying one row
 *
 * At five transports the row was already tight; SHARD made six, and six cells of
 * 10.5sp across a phone's width truncates every label to about four characters
 * ("WIRE…", "PSIP…"). A picker whose labels cannot be read is not a picker.
 *
 * So the rail lays out as a grid of [perRow] columns and as many rows as that
 * needs, and the thumb moves in both axes. With six entries at the default of
 * three per row that is two rows of three — each cell twice as wide as before,
 * so nothing is ellipsised, and the control still reads as one object rather
 * than two separate pickers.
 *
 * The caller passes labels only; the grid shape is derived. [rowCount] is public
 * so the screen can size the view without duplicating the arithmetic.
 */
class TransportRail(
    context: Context,
    private val palette: AppAppearance.Palette,
    private val labels: List<String>,
    private val perRow: Int = 3,
    private val onPick: (Int) -> Unit,
) : FrameLayout(context) {

    // MolidoVPN: a grid of mode chips (pill buttons, 16dp corners), [perRow] per
    // row, so every tunnel/core is visible at once — the previous single
    // horizontally scrolling row hid the last modes off-screen.
    // The public surface (rowCount, select, setEnabled) is unchanged.

    private val cells = mutableListOf<TextView>()
    private var selectedIndex = -1
    private val density = context.resources.displayMetrics.density

    /** MainActivity sizes the view from this. */
    val rowCount: Int = (labels.size + perRow - 1) / perRow

    init {
        val grid = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val rows = List(rowCount) { r ->
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                grid.addView(this, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f).apply {
                    if (r > 0) topMargin = context.px(8)
                })
            }
        }
        labels.forEachIndexed { index, text ->
            val chip = TextView(context).apply {
                this.text = text
                textSize = 13f
                typeface = Typefaces.medium(context)
                gravity = Gravity.CENTER
                setSingleLine(true)
                letterSpacing = spacing(0.03f)
                setPadding(context.px(16), 0, context.px(16), 0)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    if (!isEnabled) return@setOnClickListener
                    performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                    select(index, animate = true)
                    onPick(index)
                }
            }
            cells.add(chip)
            rows[index / perRow].addView(chip, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                if (index % perRow != perRow - 1) marginEnd = context.px(8)
            })
        }
        // Pad a short last row with empty cells so its chips keep the same width as the rows above.
        val lastCount = labels.size - (rowCount - 1) * perRow
        repeat(perRow - lastCount) { i ->
            rows.last().addView(View(context), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                if (lastCount + i != perRow - 1) marginEnd = context.px(8)
            })
        }
        cells.forEachIndexed { i, chip -> style(chip, i == selectedIndex) }
        addView(grid, LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        ))
    }

    private fun style(chip: TextView, on: Boolean) {
        chip.background = Sculpt.sculptedBackground(
            density,
            if (on) Sculpt.blend(palette.surface, palette.primary, 0.18f) else palette.surface,
            16,
            accent = if (on) Sculpt.withAlpha(palette.primary, 0.60f) else null,
        )
        chip.setTextColor(if (on) palette.primaryText else palette.muted)
    }

    fun select(index: Int, animate: Boolean) {
        if (index !in labels.indices) return
        selectedIndex = index
        cells.forEachIndexed { i, chip -> style(chip, i == index) }
    }

    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        alpha = if (enabled) 1f else 0.5f
        cells.forEach { it.isEnabled = enabled }
    }
}

/** Neon letter-spacing scatters Persian's joined letters — clamp for Persian. */
private fun spacing(v: Float): Float = if (AppLanguage.current() != "en") 0f else v
