//
//  DeserializeOperation.swift
//  Spine
//
//  Created by Ward van Teijlingen on 30-12-14.
//  Copyright (c) 2014 Ward van Teijlingen. All rights reserved.
//

import Foundation
import SwiftyJSON

/**
A DeserializeOperation deserializes JSON data in the form of NSData to a JSONAPIDocument.
*/
class DeserializeOperation: Operation {
	
	// Input
	fileprivate let data: JSON
	fileprivate let valueFormatters: ValueFormatterRegistry
	fileprivate let resourceFactory: ResourceFactory
	fileprivate let keyFormatter: KeyFormatter
	
	// Extracted objects
	fileprivate var extractedPrimaryResources: [Resource]?
	fileprivate var extractedIncludedResources: [Resource] = []
	fileprivate var extractedErrors: [APIError]?
	fileprivate var extractedMeta: [String: AnyObject]?
	fileprivate var extractedLinks: [String: URL]?
	fileprivate var extractedJSONAPI: [String: AnyObject]?
	fileprivate var resourcePool: [Resource] = []
	
	// Output
	var result: Failable<JSONAPIDocument, SerializerError>?
	
	
	// MARK: Initializers
	
	init(data: Data, resourceFactory: ResourceFactory, valueFormatters: ValueFormatterRegistry, keyFormatter: KeyFormatter) {
		self.data = JSON(data: data)
		self.resourceFactory = resourceFactory
		self.valueFormatters = valueFormatters
		self.keyFormatter = keyFormatter
	}
	
	
	// MARK: Mapping targets
	
	func addMappingTargets(_ targets: [Resource]) {		
		resourcePool += targets
	}
	
	
	// MARK: NSOperation
	
	override func main() {
		// Validate document
		guard data.dictionary != nil else {
			let errorMessage = "The given JSON is not a dictionary (hash).";
			Spine.logError(.serializing, errorMessage)
			result = Failable(SerializerError.invalidDocumentStructure)
			return
		}

		let hasData = data["data"].error == nil
		let hasErrors = data["errors"].error == nil
		let hasMeta = data["meta"].error == nil

		guard hasData || hasErrors || hasMeta else {
			let errorMessage = "Either 'data', 'errors', or 'meta' must be present in the top level.";
			Spine.logError(.serializing, errorMessage)
			result = Failable(SerializerError.topLevelEntryMissing)
			return
		}

		guard hasErrors && !hasData || !hasErrors && hasData else {
			let errorMessage = "Top level 'data' and 'errors' must not coexist in the same document.";
			Spine.logError(.serializing, errorMessage)
			result = Failable(SerializerError.topLevelDataAndErrorsCoexist)
			return
		}

		// Extract resources
		do {
			if let data = self.data["data"].array {
				var resources: [Resource] = []
				for (index, representation) in data.enumerated() {
					try resources.append(deserializeSingleRepresentation(representation, mappingTargetIndex: index))
				}
				extractedPrimaryResources = resources
			} else if let _ = self.data["data"].dictionary {
				let resource = try deserializeSingleRepresentation(self.data["data"], mappingTargetIndex: resourcePool.startIndex)
				extractedPrimaryResources = [resource]
			}

			if let data = self.data["included"].array {
				for representation in data {
					try extractedIncludedResources.append(deserializeSingleRepresentation(representation))
				}
			}
		} catch let error as SerializerError {
			result = Failable(error)
			return
		} catch {
			result = Failable(SerializerError.unknownError)
			return
		}
		
		// Extract errors
		extractedErrors = self.data["errors"].array?.map { error -> APIError in
			return APIError(
				id: error["id"].string,
				status: error["status"].string,
				code: error["code"].string,
				title: error["title"].string,
				detail: error["detail"].string,
				sourcePointer: error["source"]["pointer"].string,
				sourceParameter: error["source"]["source"].string,
				meta: error["meta"].dictionaryObject as [String : AnyObject]?
			)
		}
		
		// Extract meta
		extractedMeta = self.data["meta"].dictionaryObject as [String : AnyObject]?
		
		// Extract links
		if let links = self.data["links"].dictionary {
			extractedLinks = [:]
			
			for (key, value) in links {
				extractedLinks![key] = NSURL(string: value.stringValue)! as URL
			}
		}
		
		// Extract jsonapi
		extractedJSONAPI = self.data["jsonapi"].dictionaryObject as [String : AnyObject]?
		
		// Resolve relations in the store
		resolveRelations()
		
		// Create a result
		var responseDocument = JSONAPIDocument(data: nil, included: nil, errors: extractedErrors, meta: extractedMeta, links: extractedLinks as [String : URL]?, jsonapi: extractedJSONAPI)
		responseDocument.data = extractedPrimaryResources
		if !extractedIncludedResources.isEmpty {
			responseDocument.included = extractedIncludedResources
		}
		result = Failable(responseDocument)
	}
	
	
	// MARK: Deserializing
	
	/**
	Maps a single resource representation into a resource object of the given type.
	
	- parameter representation:     The JSON representation of a single resource.
	- parameter mappingTargetIndex: The index of the matching mapping target.
	
	- returns: A Resource object with values mapped from the representation.
	*/
	fileprivate func deserializeSingleRepresentation(_ representation: JSON, mappingTargetIndex: Int? = nil) throws -> Resource {
		guard representation.dictionary != nil else {
			throw SerializerError.invalidResourceStructure
		}
		
		guard let type: ResourceType = representation["type"].string else {
			throw SerializerError.resourceTypeMissing
		}
		
		guard let id = representation["id"].string else {
			throw SerializerError.resourceIDMissing
		}
		
		// Dispense a resource
		let resource = try resourceFactory.dispense(type, id: id, pool: &resourcePool, index: mappingTargetIndex)
		
		// Extract data
		resource.id = id
		resource.URL = representation["links"]["self"].URL
		resource.meta = representation["meta"].dictionaryObject as [String : AnyObject]?
		extractAttributes(representation, intoResource: resource)
		extractRelationships(representation, intoResource: resource)
		
		resource.isLoaded = true
		
		return resource
	}
	
	
	// MARK: Attributes
	
	/**
	Extracts the attributes from the given data into the given resource.
	
	This method loops over all the attributes in the passed resource, maps the attribute name
	to the key for the serialized form and invokes `extractAttribute`. It then formats the extracted
	attribute and sets the formatted value on the resource.
	
	- parameter serializedData: The data from which to extract the attributes.
	- parameter resource:       The resource into which to extract the attributes.
	*/
	fileprivate func extractAttributes(_ serializedData: JSON, intoResource resource: Resource) {
		for case let field as Attribute in resource.fields {
			let key = keyFormatter.format(field)
			if let extractedValue: AnyObject = self.extractAttribute(serializedData, key: key) {
				let formattedValue: AnyObject = self.valueFormatters.unformat(extractedValue, forAttribute: field)
				resource.setValue(formattedValue, forField: field.name)
			}
		}
	}
	
	/**
	Extracts the value for the given key from the passed serialized data.
	
	- parameter serializedData: The data from which to extract the attribute.
	- parameter key:            The key for which to extract the value from the data.
	
	- returns: The extracted value or nil if no attribute with the given key was found in the data.
	*/
	fileprivate func extractAttribute(_ serializedData: JSON, key: String) -> AnyObject? {
		let value = serializedData["attributes"][key]
		
		if let _ = value.null {
			return nil
		} else {
			return value.rawValue as AnyObject?
		}
	}
	
	
	// MARK: Relationships
	
	/**
	Extracts the relationships from the given data into the given resource.
	
	This method loops over all the relationships in the passed resource, maps the relationship name
	to the key for the serialized form and invokes `extractToOneRelationship` or `extractToManyRelationship`.
	It then sets the extracted ResourceRelationship on the resource.
	It also sets `relationships` dictionary on parent resource containing the links to all related resources.
	
	- parameter serializedData: The data from which to extract the relationships.
	- parameter resource:       The resource into which to extract the relationships.
	*/
	fileprivate func extractRelationships(_ serializedData: JSON, intoResource resource: Resource) {
		for field in resource.fields {
			let key = keyFormatter.format(field)
			resource.relationships[field.name] = extractRelationshipData(serializedData["relationships"][key])

			switch field {
			case let toOne as ToOneRelationship:
				if let linkedResource = extractToOneRelationship(serializedData, key: key, linkedType: toOne.linkedType.resourceType) {
					if resource.valueForField(toOne.name) == nil || (resource.valueForField(toOne.name) as? Resource)?.isLoaded == false {
						resource.setValue(linkedResource, forField: toOne.name)
					}
				}
			case let toMany as ToManyRelationship:
				if let linkedResourceCollection = extractToManyRelationship(serializedData, key: key) {
					if linkedResourceCollection.linkage != nil || resource.valueForField(toMany.name) == nil {
						resource.setValue(linkedResourceCollection, forField: toMany.name)
					}
				}
			default: ()
			}
		}
	}
	
	/**
	Extracts the to-one relationship for the given key from the passed serialized data.
	
	This method supports both the single ID form and the resource object forms.
	
	- parameter serializedData: The data from which to extract the relationship.
	- parameter key:            The key for which to extract the relationship from the data.
	
	- returns: The extracted relationship or nil if no relationship with the given key was found in the data.
	*/
	fileprivate func extractToOneRelationship(_ serializedData: JSON, key: String, linkedType: ResourceType) -> Resource? {
		var resource: Resource? = nil
		
		if let linkData = serializedData["relationships"][key].dictionary {
			let type = linkData["data"]?["type"].string ?? linkedType
			
			if let id = linkData["data"]?["id"].string {
				do {
					resource = try resourceFactory.dispense(type, id: id, pool: &resourcePool)
				} catch {
					resource = try! resourceFactory.dispense(linkedType, id: id, pool: &resourcePool)
				}
			} else {
				do {
					resource = try resourceFactory.instantiate(type)
				} catch {
					resource = try! resourceFactory.instantiate(linkedType)
				}
			}
			
			if let resourceURL = linkData["links"]?["related"].URL {
				resource!.URL = resourceURL
			}
		}
		
		return resource
	}
	
	/**
	Extracts the to-many relationship for the given key from the passed serialized data.
	
	This method supports both the array of IDs form and the resource object forms.
	
	- parameter serializedData: The data from which to extract the relationship.
	- parameter key:            The key for which to extract the relationship from the data.
	
	- returns: The extracted relationship or nil if no relationship with the given key was found in the data.
	*/
	fileprivate func extractToManyRelationship(_ serializedData: JSON, key: String) -> LinkedResourceCollection? {
		var resourceCollection: LinkedResourceCollection? = nil

		if let linkData = serializedData["relationships"][key].dictionary {
			let resourcesURL: URL? = linkData["links"]?["related"].URL
			let linkURL: URL? = linkData["links"]?["self"].URL
			
			if let linkage = linkData["data"]?.array {
				let mappedLinkage = linkage.map { ResourceIdentifier(type: $0["type"].stringValue, id: $0["id"].stringValue) }
				resourceCollection = LinkedResourceCollection(resourcesURL: resourcesURL, linkURL: linkURL, linkage: mappedLinkage)
			} else {
				resourceCollection = LinkedResourceCollection(resourcesURL: resourcesURL, linkURL: linkURL, linkage: nil)
			}
		}
		
		return resourceCollection
	}
	
	fileprivate func extractRelationshipData(_ linkData: JSON) -> RelationshipData {
		let selfURL = linkData["links"]["self"].URL
		let relatedURL = linkData["links"]["related"].URL
		let data: [ResourceIdentifier]?
		
		if let toOne = linkData["data"].dictionary {
			data = [ResourceIdentifier(type: toOne["type"]!.stringValue, id: toOne["id"]!.stringValue)]
		} else if let toMany = linkData["data"].array {
			data = toMany.map { JSON -> ResourceIdentifier in
				return ResourceIdentifier(type: JSON["type"].stringValue, id: JSON["id"].stringValue)
			}
		} else {
			data = nil
		}
		
		return RelationshipData(selfURL: selfURL, relatedURL: relatedURL, data: data)
	}
	
	/**
	Resolves the relations of the fetched resources.
	*/
	fileprivate func resolveRelations() {
		for resource in resourcePool {
			for case let field as ToManyRelationship in resource.fields {
				
				guard let linkedResourceCollection = resource.valueForField(field.name) as? LinkedResourceCollection else {
					Spine.logInfo(.serializing, "Cannot resolve relationship '\(field.name)' of \(resource.resourceType):\(resource.id!) because the JSON did not include the relationship.")
					continue
				}
				
				guard let linkage = linkedResourceCollection.linkage else {
					Spine.logInfo(.serializing, "Cannot resolve relationship '\(field.name)' of \(resource.resourceType):\(resource.id!) because the JSON did not include linkage.")
					continue
				}
					
				let targetResources = linkage.flatMap { (link: ResourceIdentifier) in
					return self.resourcePool.filter { $0.resourceType == link.type && $0.id == link.id }
				}
				
				if !targetResources.isEmpty {
					linkedResourceCollection.resources = targetResources
					linkedResourceCollection.isLoaded = true
				}
				
			}
		}
	}
}
