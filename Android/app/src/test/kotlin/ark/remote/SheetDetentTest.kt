package ark.remote

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test
import skip.lib.setOf
import skip.ui.PresentationDetent

/// 0.5.2 r5: on Android the review sheet (SaveBar.swift, `.presentationDetents([.medium, .large])`) and the 诊断记录
/// sheet jumped between half and full height while open (7 of 12 openings on ark37 within 12 s,
/// BOARD/app-work/0.5.2/r5/sheet-watch.txt), so a tap aimed at its ✕ or 寄出 could land on something else. skip-ui took
/// `detents.first` of a set that skip-fuse-ui fills in the order Swift iterates it, which changes from one evaluation
/// of the view to the next. The vendored patch (Vendor/skip-ui/VENDORED.md) keeps every detent and shows the smallest,
/// as UIKit opens a sheet with no selected detent. These pin that the choice does not depend on the set's order.
class SheetDetentTest {
    private val screen = 900.dp
    private val large = 80.dp

    @Test
    fun mediumAndLargeShowMediumInEitherOrder() {
        val a = PresentationDetent.sheetInset(setOf(PresentationDetent.medium, PresentationDetent.large), screen, large)
        val b = PresentationDetent.sheetInset(setOf(PresentationDetent.large, PresentationDetent.medium), screen, large)
        assertEquals(450.dp, a)
        assertEquals(450.dp, b)
    }

    @Test
    fun theSmallestOfFractionsAndHeightsWins() {
        val d = setOf(PresentationDetent.large, PresentationDetent.fraction(0.25), PresentationDetent.height(400.0),
            PresentationDetent.medium)
        assertEquals(screen * 0.75f, PresentationDetent.sheetInset(d, screen, large))
    }

    @Test
    fun largeAloneAndNoneKeepTheLargeInset() {
        assertEquals(large, PresentationDetent.sheetInset(setOf(PresentationDetent.large), screen, large))
        assertEquals(large, PresentationDetent.sheetInset(setOf<PresentationDetent>(), screen, large))
    }
}
