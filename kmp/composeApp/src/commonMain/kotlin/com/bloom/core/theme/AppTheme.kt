package com.bloom.core.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object AppColors {
    val Beige = Color(0xFFF5ECD7)
    val Sage = Color(0xFF7A9E7E)
    val Cream = Color(0xFFFFFBF2)
    val Earth = Color(0xFFC4956A)
    val DarkEarth = Color(0xFF8B6347)
    val SoftGray = Color(0xFFB0A89A)
    val TextDark = Color(0xFF3D2B1F)
    val TextMedium = Color(0xFF6B5344)
    val White = Color(0xFFFFFFFF)
    val Error = Color(0xFFD64045)

    val BoyColors = listOf(
        "#7EC8C8", "#6BB8A8", "#5B9EA0", "#4A9BBD", "#5F8FA8",
        "#7BADC0", "#89B4C9", "#6BA3C0"
    )
    val GirlColors = listOf(
        "#C4956A", "#D4A373", "#C9956A", "#B8866A", "#D4956A",
        "#C49070", "#BF8C78", "#D4A06A"
    )
}

private val LightColorScheme = lightColorScheme(
    primary = AppColors.Sage,
    secondary = AppColors.Earth,
    surface = AppColors.Cream,
    background = AppColors.Beige,
    error = AppColors.Error,
    onPrimary = AppColors.White,
    onSecondary = AppColors.White,
    onSurface = AppColors.TextDark,
    onBackground = AppColors.TextDark,
)

private val BloomTypography = Typography(
    headlineLarge = TextStyle(
        fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.Bold,
        fontSize = 32.sp,
        color = AppColors.TextDark,
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 24.sp,
        color = AppColors.TextDark,
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        color = AppColors.TextDark,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontSize = 16.sp,
        color = AppColors.TextDark,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontSize = 14.sp,
        color = AppColors.TextMedium,
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 16.sp,
    ),
)

private val BloomShapes = Shapes(
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(20.dp),
)

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = LightColorScheme,
        typography = BloomTypography,
        shapes = BloomShapes,
        content = content,
    )
}
