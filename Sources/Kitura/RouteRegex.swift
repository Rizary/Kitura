/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import KituraSys
import LoggerAPI

import Foundation

public class RouteRegex {
    public static let sharedInstance = RouteRegex()
    
    private var namedCaptureRegex: NSRegularExpression?
    private var unnamedCaptureRegex: NSRegularExpression?
    
    private init () {
        do {
            namedCaptureRegex = try NSRegularExpression(pattern: "(.*)?(?:\\:(\\w+)(?:\\(((?:\\\\.|[^()])+)\\))?(?:([+*?])?))", options: [])
            unnamedCaptureRegex = try NSRegularExpression(pattern: "(.*)?(?:(?:\\(((?:\\\\.|[^()])+)\\))(?:([+*?])?))", options: [])
        } catch {
            Log.error("Failed to create regular expressions used to parse Route patterns")
        }
    }
    
    ///
    /// Builds a regular expression from a String pattern
    ///
    /// - Parameter pattern: Optional string
    ///
    /// - Returns:
    ///
    internal func buildRegex(fromPattern: String?, allowPartialMatch: Bool = false) -> (NSRegularExpression?, [String]?) {
        
        guard let fromPattern = fromPattern else {
            return (nil, nil)
        }

        guard let keyRegex = namedCaptureRegex else {
            Log.error("RouteRegex has invalid state: missing keyRegex")
            return (nil, nil)
        }
        guard let nonKeyRegex = unnamedCaptureRegex else {
            Log.error("RouteRegex element has invalid state: missing nonKeyRegex")
            return (nil, nil)
        }

        var pattern = fromPattern
        var regexStr = "^"
        var keys = [String]()
        var nonKeyIndex = 0
        
        if allowPartialMatch && pattern.hasSuffix("*") {
            pattern = String(pattern.characters.dropLast())
        }
        
        let paths = pattern.bridge().components(separatedBy: "/")
        
        // Special case where only back slashes are specified
        if paths.filter({$0 != ""}).isEmpty {
            regexStr.append("/")
        }
        
        for path in paths {
            (regexStr, keys, nonKeyIndex) =
                handlePath(path, regexStr: regexStr, keys: keys, nonKeyIndex: nonKeyIndex,
                           keyRegex: keyRegex, nonKeyRegex: nonKeyRegex)
        }

        regexStr.append("(?:/(?=$))?")
        if !allowPartialMatch {
            regexStr.append("$")
        }

        var regex: NSRegularExpression? = nil
        do {
            regex = try NSRegularExpression(pattern: regexStr, options: [])
        } catch {
            Log.error("Failed to compile the regular expression for the route \(pattern)")
        }

        return (regex, keys)
    }

    func handlePath(_ path: String, regexStr: String, keys: [String], nonKeyIndex: Int,
                    keyRegex: NSRegularExpression, nonKeyRegex: NSRegularExpression) ->
                    (regexStr: String, keys: [String], nonKeyIndex: Int) {

            var nonKeyIndex = nonKeyIndex
            var keys = keys
            var regexStr = regexStr

            // If there was a leading slash, there will be an empty component in the split
            if  path.isEmpty {
                return (regexStr, keys, nonKeyIndex)
            }

            let (matched, prefix, matchExp, plusQuestStar) =
                matchRangesInPath(path, keyRegex: keyRegex, nonKeyRegex: nonKeyRegex,
                                  nonKeyIndex: &nonKeyIndex, keys: &keys)

            let toAppend = getStringToAppendToRegex(matched: matched, plusQuestStar: plusQuestStar,
                                                    prefix: prefix, path: path, matchExp: matchExp)
            regexStr.append(toAppend)
            return (regexStr, keys, nonKeyIndex)
    }

    func matchRangesInPath(_ path: String, keyRegex: NSRegularExpression, nonKeyRegex: NSRegularExpression, nonKeyIndex: inout Int, keys: inout [String]) ->
        (match: Bool, prefix: String, matchExp: String, plusQuestStar: String) {
        var matched = false
        var prefix = ""
        var matchExp = "[^/]+?"
        var plusQuestStar = ""

        if  path == "*" {
            // Handle a path element of * specially
            return (true, prefix, ".*", plusQuestStar)
        }

        let range = NSMakeRange(0, path.characters.count)

        if let keyMatch = keyRegex.firstMatch(in: path, options: [], range: range) {
            // We found a path element with a named/key capture
            let prefixRange = keyMatch.range(at: 1)
            if  prefixRange.location != NSNotFound  &&  prefixRange.location != -1 {
                prefix = path.bridge().substring(with: prefixRange)
            }
            let matchExpRange = keyMatch.range(at: 3)
            if  matchExpRange.location != NSNotFound  &&  matchExpRange.location != -1 {
                matchExp = path.bridge().substring(with: matchExpRange)
            }
            let pqsRange = keyMatch.range(at: 4)
            if  pqsRange.location != NSNotFound  &&  pqsRange.location != -1 {
                plusQuestStar = path.bridge().substring(with: pqsRange)
            }
            keys.append(path.bridge().substring(with: keyMatch.range(at: 2)))
            matched = true
        } else if let nonKeyMatch = nonKeyRegex.firstMatch(in: path, options: [], range: range) {
            // We found a path element with an unnamed capture
            let prefixRange = nonKeyMatch.range(at: 1)
            if  prefixRange.location != NSNotFound  &&  prefixRange.location != -1 {
                prefix = path.bridge().substring(with: prefixRange)
            }
            let matchExpRange = nonKeyMatch.range(at: 2)
            if  matchExpRange.location != NSNotFound  &&  matchExpRange.location != -1 {
                matchExp = path.bridge().substring(with: matchExpRange)
            }
            let pqsRange = nonKeyMatch.range(at: 3)
            if  pqsRange.location != NSNotFound  &&  pqsRange.location != -1 {
                plusQuestStar = path.bridge().substring(with: pqsRange)
            }
            keys.append(String(nonKeyIndex))
            nonKeyIndex+=1
            matched = true
        }

        return (matched, prefix, matchExp, plusQuestStar)
    }

    func getStringToAppendToRegex(matched: Bool, plusQuestStar: String, prefix: String,
                            path: String, matchExp: String) -> String {
        if  !matched  { // A path element with no capture
            return "/\(path)"
        }

        // We have some kind of capture for this path element
        // Build the runtime regex depending on whether or not there is "repetition"
        switch(plusQuestStar) {
        case "+":
            return "/\(prefix)(\(matchExp)(?:/\(matchExp))*)"
        case "?":
            if  prefix.isEmpty {
                return "(?:/(\(matchExp)))?"
            } else {
                return "/\(prefix)(?:(\(matchExp)))?"
            }
        case "*":
            if  prefix.isEmpty {
                return "(?:/(\(matchExp)(?:/\(matchExp))*))?"
            } else {
                return "/\(prefix)(?:(\(matchExp)(?:/\(matchExp))*))?"
            }
        default:
            return "/\(prefix)(?:(\(matchExp)))"
        }
    }
}
