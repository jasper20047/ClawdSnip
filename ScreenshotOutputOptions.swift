import Foundation

struct ScreenshotOutputOptions: Equatable {
 var saveToFile:Bool
 var autoPaste:Bool
 static func saved(in defaults:UserDefaults = .standard)->Self {
  Self(saveToFile:defaults.object(forKey:"saveScreenshots") as? Bool ?? false,
       autoPaste:defaults.object(forKey:"autoPaste") as? Bool ?? true)
 }
 func save(in defaults:UserDefaults = .standard) {
  defaults.set(saveToFile,forKey:"saveScreenshots")
  defaults.set(autoPaste,forKey:"autoPaste")
 }
}
