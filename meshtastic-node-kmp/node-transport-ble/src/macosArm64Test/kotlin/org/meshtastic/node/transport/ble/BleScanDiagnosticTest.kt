package org.meshtastic.node.transport.ble

import com.juul.kable.Scanner
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.meshtastic.node.ble.BleMeshAdvert
import platform.posix.getenv
import kotlin.test.Test
import kotlin.time.Duration.Companion.seconds

/** Which layer is losing the advertisements: the scan, the filter, or our decoder. */
@OptIn(ExperimentalForeignApi::class)
class BleScanDiagnosticTest {

    @Test
    fun `compare an unfiltered scan with the transport's filtered one`() = runBlocking {
        if (getenv("MESH_BLE_DIAGNOSE")?.toKString() == null) return@runBlocking

        // Bounded by time, not by count: in a dense room a take(n) fills from nearby phones and
        // beacons within seconds, long before a radio's next mesh advertisement, and then reports
        // zero mesh frames as though none existed.
        val unfiltered = mutableListOf<com.juul.kable.Advertisement>()
        withTimeoutOrNull(40.seconds) {
            Scanner().advertisements.collect { unfiltered += it }
        }
        val withCompanyId = unfiltered.filter { it.manufacturerData(BleMeshAdvert.COMPANY_ID) != null }
        val decodable = withCompanyId.mapNotNull {
            BleMeshAdvert.extractPacketFromBody(it.manufacturerData(BleMeshAdvert.COMPANY_ID)!!)
        }

        println("diag: unfiltered=${unfiltered.size} companyId=${withCompanyId.size} decodable=${decodable.size}")
        withCompanyId.take(2).forEach {
            val b = it.manufacturerData(BleMeshAdvert.COMPANY_ID)!!
            println("diag: body ${b.size}B ${b.take(12).joinToString("") { x -> (x.toInt() and 0xFF).toString(16).padStart(2, '0') }}")
        }

        val filtered = withTimeoutOrNull(25.seconds) {
            BleMeshTransport().incoming().take(1).toList()
        }.orEmpty()
        println("diag: through the transport's own scanner = ${filtered.size}")
    }
}
