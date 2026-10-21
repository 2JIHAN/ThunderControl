import Foundation
import CoreGraphics
if let event = DGCreateMemoryFixture(), let a = event.data, let clone = DGEventFromData(a), let b = clone.data {
 print("fixture encoded bytes=\(CFDataGetLength(a)); ISC raw suffix=\(DGHasISCRawSuffix(a)); serialized roundtrip equality=\(CFEqual(a,b)); second raw suffix=\(DGHasISCRawSuffix(b))")
} else { print("fixture creation unavailable") }
