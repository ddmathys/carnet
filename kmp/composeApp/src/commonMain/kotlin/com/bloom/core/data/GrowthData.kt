package com.bloom.core.data

data class GrowthPoint(val month: Int, val p3: Double, val p50: Double, val p97: Double)

val kWeightBoys = listOf(
    GrowthPoint(0,  2.5,  3.3,  4.4),
    GrowthPoint(1,  3.4,  4.5,  5.8),
    GrowthPoint(2,  4.4,  5.6,  7.1),
    GrowthPoint(3,  5.1,  6.4,  8.0),
    GrowthPoint(4,  5.7,  7.0,  8.7),
    GrowthPoint(5,  6.1,  7.5,  9.3),
    GrowthPoint(6,  6.4,  7.9,  9.7),
    GrowthPoint(7,  6.7,  8.3,  10.2),
    GrowthPoint(8,  7.0,  8.6,  10.5),
    GrowthPoint(9,  7.2,  8.9,  10.9),
    GrowthPoint(10, 7.5,  9.2,  11.2),
    GrowthPoint(11, 7.7,  9.4,  11.5),
    GrowthPoint(12, 7.8,  9.6,  11.8),
    GrowthPoint(15, 8.3,  10.3, 12.6),
    GrowthPoint(18, 8.8,  10.9, 13.4),
    GrowthPoint(21, 9.2,  11.5, 14.1),
    GrowthPoint(24, 9.7,  12.2, 15.0),
)

val kWeightGirls = listOf(
    GrowthPoint(0,  2.4,  3.2,  4.2),
    GrowthPoint(1,  3.2,  4.2,  5.5),
    GrowthPoint(2,  3.9,  5.1,  6.6),
    GrowthPoint(3,  4.5,  5.8,  7.5),
    GrowthPoint(4,  5.0,  6.4,  8.2),
    GrowthPoint(5,  5.4,  6.9,  8.8),
    GrowthPoint(6,  5.7,  7.3,  9.3),
    GrowthPoint(7,  6.0,  7.6,  9.8),
    GrowthPoint(8,  6.3,  7.9,  10.2),
    GrowthPoint(9,  6.5,  8.2,  10.5),
    GrowthPoint(10, 6.7,  8.5,  10.9),
    GrowthPoint(11, 6.9,  8.7,  11.2),
    GrowthPoint(12, 7.1,  8.9,  11.5),
    GrowthPoint(15, 7.6,  9.6,  12.4),
    GrowthPoint(18, 8.1,  10.2, 13.2),
    GrowthPoint(21, 8.6,  10.9, 14.0),
    GrowthPoint(24, 9.0,  11.5, 14.8),
)

val kHeightBoys = listOf(
    GrowthPoint(0,  46.3, 49.9, 53.4),
    GrowthPoint(1,  50.8, 54.7, 58.6),
    GrowthPoint(2,  54.4, 58.4, 62.4),
    GrowthPoint(3,  57.3, 61.4, 65.5),
    GrowthPoint(4,  59.7, 63.9, 68.0),
    GrowthPoint(5,  61.7, 65.9, 70.1),
    GrowthPoint(6,  63.3, 67.6, 71.9),
    GrowthPoint(7,  64.8, 69.2, 73.5),
    GrowthPoint(8,  66.2, 70.6, 75.0),
    GrowthPoint(9,  67.5, 72.0, 76.5),
    GrowthPoint(10, 68.7, 73.3, 77.9),
    GrowthPoint(11, 69.9, 74.5, 79.2),
    GrowthPoint(12, 71.0, 75.7, 80.5),
    GrowthPoint(15, 73.9, 79.1, 84.2),
    GrowthPoint(18, 76.9, 82.3, 87.7),
    GrowthPoint(21, 79.4, 85.1, 90.7),
    GrowthPoint(24, 81.7, 87.8, 93.9),
)

val kHeightGirls = listOf(
    GrowthPoint(0,  45.6, 49.1, 52.7),
    GrowthPoint(1,  49.8, 53.7, 57.6),
    GrowthPoint(2,  53.0, 57.1, 61.1),
    GrowthPoint(3,  55.6, 59.8, 64.0),
    GrowthPoint(4,  57.8, 62.1, 66.4),
    GrowthPoint(5,  59.6, 64.0, 68.5),
    GrowthPoint(6,  61.2, 65.7, 70.3),
    GrowthPoint(7,  62.7, 67.3, 71.9),
    GrowthPoint(8,  64.0, 68.7, 73.5),
    GrowthPoint(9,  65.3, 70.1, 75.0),
    GrowthPoint(10, 66.5, 71.5, 76.4),
    GrowthPoint(11, 67.7, 72.8, 77.8),
    GrowthPoint(12, 68.9, 74.0, 79.2),
    GrowthPoint(15, 72.0, 77.5, 83.1),
    GrowthPoint(18, 74.9, 80.7, 86.5),
    GrowthPoint(21, 77.5, 83.7, 89.9),
    GrowthPoint(24, 80.0, 86.4, 92.9),
)

fun getGrowthData(gender: String, isWeight: Boolean): List<GrowthPoint> =
    if (isWeight) if (gender == "boy") kWeightBoys else kWeightGirls
    else if (gender == "boy") kHeightBoys else kHeightGirls
