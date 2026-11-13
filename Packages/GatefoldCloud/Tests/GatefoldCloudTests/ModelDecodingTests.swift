import Foundation
import Testing
@testable import GatefoldCloud

func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Suite("Wire model decoding (recorded fixtures)")
struct ModelDecodingTests {
    @Test func decodesTheStoreLookup() throws {
        let stores = try WireDecoder.stores(Fixture.data("auth-providers.json"))
        #expect(stores == [CloudStore(alias: "pocketbook_de", name: "Pocketbook.de", shopID: "1",
                                      iconURL: URL(string: "https://pocketbook.de/static/version1793097427/webapi_rest/_view/de_DE/images/logo.svg"),
                                      loggedBy: "password")])
        #expect(stores[0].usesPassword)
    }

    @Test func decodesTheTokenResponse() throws {
        let token = try WireDecoder.token(Fixture.data("auth-token.json"), now: utc("2026-10-31T22:00:00Z"))
        #expect(token.accessToken == "REDACTED-access_token")
        #expect(token.refreshToken == "REDACTED-refresh_token")
        #expect(token.expiresAt == utc("2026-11-01T00:00:00Z"))
    }

    @Test func decodesALibraryPage() throws {
        let page = try WireDecoder.booksPage(Fixture.data("books-page.json"))
        #expect(page.total == 2)
        let book = try #require(page.items.first)
        #expect(book.fastHash == "56f8619536655be4a1541a40c5702d32")
        #expect(book.cloudID == "104277029")
        #expect(book.title == "Frankenstein; or, The modern Prometheus")
        #expect(book.authors == "Mary Wollstonecraft Shelley")
        #expect(book.format == "epub")
        #expect(book.bytes == 440131)
        #expect(book.md5Base64 == "HpCKqamClMQ9Aai870mKVQ==")
        #expect(book.modifiedAt == utc("2026-10-31T21:56:44Z"))
        #expect(book.coverURL?.absoluteString.contains("cover_s.jpg") == true)
        #expect(book.largeCoverURL?.absoluteString.contains("cover_b.jpg") == true)
        #expect(book.downloadURL?.absoluteString.contains("signature-download") == true)
        #expect(book.position == nil, "a book never opened has no position")
        #expect(book.readStatus == nil)
    }

    @Test func decodesTheFileInfoPosition() throws {
        let info = try WireDecoder.fileInfo(Fixture.data("fileops-info.json"))
        let position = try #require(info.position)
        #expect(position.cfi == "epubcfi(/6/8!/4/2/4/1:0)")
        #expect(position.pointer == "pbr:/external##epubcfi(/6/8!/4/2/4/1:0)")
        #expect(position.totalProgression == 0.05)
        #expect(position.updated == utc("2026-10-31T21:59:16Z"))
        #expect(position.source == .pocketBookNative)
        #expect(info.book?.bytes == 440131)
    }

    @Test func decodesTheFileInfoPositionUpdatedInMilliseconds() throws {
        let info = try WireDecoder.fileInfo(Fixture.data("fileops-info-milliseconds.json"))
        let position = try #require(info.position)
        #expect(position.updated == Date(timeIntervalSince1970: 1_763_054_791))
        #expect(position.cfi == "epubcfi(/6/8!/4/2/4/1:0)")
        #expect(position.totalProgression == 0.05)
    }

    @Test func decodesTheUploadResponseWithItsOddTypes() throws {
        let book = try WireDecoder.uploadResponse(Fixture.data("upload-response.json"))
        #expect(book.fastHash == "56f8619536655be4a1541a40c5702d32")
        #expect(book.bytes == 440131, "bytes arrives as a string here")
        #expect(book.modifiedAt == utc("2026-10-31T21:56:29Z"), "mtime arrives as 'yyyy-MM-dd HH:mm:ss' here")
    }

    @Test func decodesTheUserAsAnAccount() throws {
        let store = CloudStore(alias: "pocketbook_de", name: "Pocketbook.de", shopID: "1", iconURL: nil, loggedBy: "password")
        let account = try WireDecoder.account(Fixture.data("user.json"), store: store)
        #expect(account.email == "reader@example.com")
        #expect(account.displayName == "Gatefold Test One")
        #expect(account.mailInAddress == "user1000001.pbookde@pbsync.com")
        #expect(account.quotaBytes == 5_368_709_120)
        #expect(account.store == store)
    }

    @Test func decodesAnnotations() throws {
        let note = try WireDecoder.annotation(Fixture.data("note.json"))
        #expect(note.uuid == "d1c0a338-a35f-4e57-8104-3f8bd5a09820")
        #expect(note.kind.value == .highlight)
        #expect(note.color?.value == .yellow)
        #expect(note.note?.value == "partial update")
        #expect(note.note?.updated == utc("2026-10-31T22:00:59Z"))
        #expect(note.quotation?.value.begin == "#epubcfi(/6/8!/4/2/4/1:0)")
        #expect(note.quotation?.value.text == "probe text")
        #expect(note.mark?.value.anchor == "#epubcfi(/6/8!/4/2/4/1:0)")
        #expect(note.mark?.value.created == Date(timeIntervalSince1970: 1793484031))

        let list = try WireDecoder.annotationList(Fixture.data("notes-list.json"))
        #expect(list == [.init(uuid: "d1c0a338-a35f-4e57-8104-3f8bd5a09820", kind: .highlight, updated: utc("2026-10-31T22:00:31Z"))])
        let wrapped = try WireDecoder.annotationList(Data(#"{"total":1,"items":[{"uuid":"u","type":"bookmark","updated":1793484031}]}"#.utf8))
        #expect(wrapped == [.init(uuid: "u", kind: .bookmark, updated: Date(timeIntervalSince1970: 1793484031))])
    }

    @Test func keepsUnknownColorsAndKinds() throws {
        let json = #"{"uuid":"x","type":{"value":"sticker","updated":1},"color":{"value":"cian","updated":1}}"#
        let note = try WireDecoder.annotation(Data(json.utf8))
        #expect(note.kind.value == .other("sticker"))
        #expect(note.color?.value == .cyan)
        #expect(AnnotationColor.cyan.wireValue == "cian")
    }

    @Test func parsesEveryDateFormTheCloudSends() {
        #expect(PBDate.parse("2026-10-31T21:56:29Z") == utc("2026-10-31T21:56:29Z"))
        #expect(PBDate.parse("2026-10-31 21:56:29") == utc("2026-10-31T21:56:29Z"))
        #expect(PBDate.parse("2026-10-31T21:56:29.123Z")?.timeIntervalSince1970.rounded() == utc("2026-10-31T21:56:29Z").timeIntervalSince1970)
        #expect(PBDate.parse("2026-10-31T23:56:29+02:00") == utc("2026-10-31T21:56:29Z"))
        #expect(PBDate.parse("1793484031") == Date(timeIntervalSince1970: 1793484031))
        #expect(PBDate.parse("") == nil)
        #expect(PBDate.parse("soon") == nil)
    }

    @Test func interpretsNumericDatesInSecondsOrMilliseconds() {
        #expect(Loose.number(1_763_054_791).date == Date(timeIntervalSince1970: 1_763_054_791))
        #expect(Loose.number(100_000_000_000).date == Date(timeIntervalSince1970: 100_000_000_000))
        #expect(Loose.number(100_000_000_001).date == Date(timeIntervalSince1970: 100_000_000.001))
        #expect(Loose.number(1_763_054_791_250).date == Date(timeIntervalSince1970: 1_763_054_791.25))
    }
}

@Suite("Wire model encoding")
struct ModelEncodingTests {
    @Test func encodesAPositionLikeTheWebReaderPlusNativePointer() throws {
        let position = ReadingPosition(cfi: "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)", totalProgression: 0.0861, updated: utc("2026-10-31T22:30:00Z"))
        let body = try JSONSerialization.jsonObject(with: WireEncoder.positionBody(position, pointerStyle: .external)) as! [String: Any]
        #expect(body["pointer"] as? String == "#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(body["pointer_pb"] as? String == "pbr:/external##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(body["offs"] as? Int == 9, "the web reader sends ceil(100 × progress)")
        #expect(body["page"] == nil)
    }

    @Test func theCloudPercentIsTheSameWholePercentEverywhere() throws {
        for whole in [0, 1, 7, 14, 28, 29, 57, 99, 100] {
            let position = ReadingPosition(cfi: nil, totalProgression: Double(whole) / 100, updated: utc("2026-10-31T22:30:00Z"))
            let body = try JSONSerialization.jsonObject(with: WireEncoder.positionBody(position, pointerStyle: .external)) as! [String: Any]
            #expect(body["offs"] as? Int == whole, "\(whole)% must not gain a percent from floating-point noise")
            #expect(position.wholePercent == whole)
        }
    }

    @Test func percentOnlyPlacesMatchByTheirWholePercent() {
        let t = utc("2026-10-31T22:30:00Z")
        let ours = ReadingPosition(cfi: nil, totalProgression: 0.301, updated: t)
        // What the Cloud hands back after we send ceil(30.1) = 31.
        let readBack = ReadingPosition(cfi: nil, totalProgression: 0.31, updated: t, source: .unknown)
        #expect(ours.isSameLocation(as: readBack))
        #expect(!ours.isSameLocation(as: ReadingPosition(cfi: nil, totalProgression: 0.32, updated: t)))
    }

    @Test func encodesAnnotationFieldsWithTheirOwnTimestamps() throws {
        var note = CloudAnnotation.highlight(begin: "#epubcfi(/6/8!/4/2/4/1:0)", end: "#epubcfi(/6/8!/4/2/4/1:20)", text: "quoted", color: .cyan, at: utc("2026-10-31T22:00:00Z"))
        note.note = .init("my thought", updated: utc("2026-10-31T22:05:00Z"))
        let body = try JSONSerialization.jsonObject(with: WireEncoder.annotationBody(note)) as! [String: Any]
        #expect((body["type"] as? [String: Any])?["value"] as? String == "highlight")
        #expect((body["color"] as? [String: Any])?["value"] as? String == "cian")
        #expect((body["note"] as? [String: Any])?["text"] as? String == "my thought")
        #expect((body["note"] as? [String: Any])?["updated"] as? String == "2026-10-31T22:05:00Z")
        #expect((body["quotation"] as? [String: Any])?["end"] as? String == "#epubcfi(/6/8!/4/2/4/1:20)")
        #expect((body["mark"] as? [String: Any])?["created"] as? Int == Int(utc("2026-10-31T22:00:00Z").timeIntervalSince1970))
        #expect(body["uuid"] == nil)
    }

    @Test func encodesOnlyTheFieldsGivenForAPartialUpdate() throws {
        let body = try JSONSerialization.jsonObject(with: WireEncoder.annotationPatch(color: .init(.red, updated: utc("2026-10-31T22:01:30Z")))) as! [String: Any]
        #expect(Set(body.keys) == ["color"])
    }
}
