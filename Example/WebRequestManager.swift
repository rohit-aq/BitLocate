//
//  WebRequestManager.swift
//  indeclap
//
//  Created by Huulke on 12/14/17.
//  Copyright © 2017 Huulke. All rights reserved.
//

import UIKit
import Alamofire

class WebRequestManager: NSObject {
    
    var lastRequest:DataRequest?
    
    func httpRequest(method type:HTTPFunction, apiURL url:String, body parameters:Dictionary<String,Any>, completion success:@escaping(_ response:Dictionary<String, Any>) -> Void, failure errorOccured:@escaping (_ error:String) ->Void ) {
        let requestURL = URL.init(string: url)
        let httpMethod = HTTPMethod.init(rawValue: type.rawValue)!
        print("API Request with URL: \(requestURL!.absoluteString) and Parameters: \(parameters)")
       lastRequest =  Alamofire.request(requestURL!, method: httpMethod, parameters: parameters, encoding: JSONEncoding.default, headers: nil).responseJSON { (response) in
            print("Response \(response)")
            switch response.result {
            case .success:
                if let responseBody = response.result.value as? Dictionary<String,Any> {
                    // API request complete with response
                    success(responseBody)
                }
            case .failure(let error):
                // API Request failed with error
                print("Error occured in API Request: \(url) --> Error Description \(error.localizedDescription)")
                errorOccured(error.localizedDescription)
            }
        }
    }
}

enum HTTPFunction: String {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}



