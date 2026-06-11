package com.bloom.features.milestones.widgets

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.data.GrowthPoint
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors

data class MeasurementPoint(val ageMonths: Int, val value: Double)

@Composable
fun GrowthCurveChart(
    referenceData: List<GrowthPoint>,
    childPoints: List<MeasurementPoint>,
    isWeight: Boolean,
    modifier: Modifier = Modifier,
) {
    val textMeasurer = rememberTextMeasurer()

    Canvas(modifier = modifier.fillMaxWidth().height(260.dp)) {
        val padLeft = 48f
        val padBottom = 36f
        val padTop = 16f
        val padRight = 16f
        val chartW = size.width - padLeft - padRight
        val chartH = size.height - padBottom - padTop

        val maxMonth = 24
        val minMonth = 0

        val allYValues = referenceData.flatMap { listOf(it.p3, it.p97) } +
                childPoints.map { it.value }
        val minY = (allYValues.minOrNull() ?: 0.0) * 0.97
        val maxY = (allYValues.maxOrNull() ?: 1.0) * 1.03

        fun toX(month: Int) = padLeft + (month - minMonth).toFloat() / (maxMonth - minMonth) * chartW
        fun toY(value: Double) = padTop + chartH - ((value - minY) / (maxY - minY) * chartH).toFloat()

        // Background
        drawRect(color = Color(0xFFFFFBF2), topLeft = Offset(padLeft, padTop), size = androidx.compose.ui.geometry.Size(chartW, chartH))

        // Grid lines (horizontal)
        val ySteps = 5
        repeat(ySteps + 1) { i ->
            val yVal = minY + (maxY - minY) * i / ySteps
            val y = toY(yVal).coerceIn(padTop, padTop + chartH)
            drawLine(color = Color(0xFFE0D8C8), start = Offset(padLeft, y), end = Offset(padLeft + chartW, y), strokeWidth = 1f)
            // Y label
            val label = if (isWeight) yVal.toFixed1() else "${yVal.toInt()}"
            drawText(
                textMeasurer = textMeasurer,
                text = label,
                topLeft = Offset(2f, y - 8f),
                style = TextStyle(fontSize = 9.sp, color = AppColors.TextMedium),
            )
        }

        // Axes
        drawLine(color = AppColors.SoftGray, start = Offset(padLeft, padTop), end = Offset(padLeft, padTop + chartH), strokeWidth = 1.5f)
        drawLine(color = AppColors.SoftGray, start = Offset(padLeft, padTop + chartH), end = Offset(padLeft + chartW, padTop + chartH), strokeWidth = 1.5f)

        // X labels
        listOf(0, 3, 6, 9, 12, 15, 18, 21, 24).forEach { m ->
            val x = toX(m)
            drawLine(color = AppColors.SoftGray, start = Offset(x, padTop + chartH), end = Offset(x, padTop + chartH + 4f), strokeWidth = 1f)
            drawText(
                textMeasurer = textMeasurer,
                text = "$m",
                topLeft = Offset(x - 8f, padTop + chartH + 6f),
                style = TextStyle(fontSize = 9.sp, color = AppColors.TextMedium),
            )
        }

        // Reference curves (p3, p50, p97)
        if (referenceData.size >= 2) {
            drawGrowthLine(referenceData.map { Offset(toX(it.month), toY(it.p3)) }, Color(0xFFA8C5A8), 1.5f, true)
            drawGrowthLine(referenceData.map { Offset(toX(it.month), toY(it.p50)) }, AppColors.Sage, 2f, false)
            drawGrowthLine(referenceData.map { Offset(toX(it.month), toY(it.p97)) }, Color(0xFFA8C5A8), 1.5f, true)
        }

        // Child's measurements
        if (childPoints.isNotEmpty()) {
            val points = childPoints.sortedBy { it.ageMonths }.map { Offset(toX(it.ageMonths), toY(it.value)) }
            if (points.size >= 2) {
                drawGrowthLine(points, AppColors.Earth, 2.5f, false)
            }
            points.forEach { pt ->
                drawCircle(color = AppColors.Earth, radius = 5f, center = pt)
                drawCircle(color = AppColors.White, radius = 2.5f, center = pt)
            }
        }
    }
}

private fun Double.toFixed1(): String {
    val intPart = this.toInt()
    val decPart = ((this - intPart) * 10 + 0.5).toInt().coerceIn(0, 9)
    return "$intPart.$decPart"
}

private fun DrawScope.drawGrowthLine(points: List<Offset>, color: Color, width: Float, dashed: Boolean) {
    if (points.size < 2) return
    val path = Path()
    path.moveTo(points.first().x, points.first().y)
    for (i in 1 until points.size) {
        path.lineTo(points[i].x, points[i].y)
    }
    drawPath(
        path = path,
        color = color,
        style = Stroke(width = width),
    )
}
