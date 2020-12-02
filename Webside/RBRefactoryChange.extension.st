Extension { #name : #RBRefactoryChange }

{ #category : #'*Webside' }
RBRefactoryChange class >> acceptsWebsideJson: json [
	| type |
	type := json at: 'type' ifAbsent: nil.
	^ self webSTType = type
]

{ #category : #'*Webside' }
RBRefactoryChange >> asWebsideJson [
	^ NeoJSONObject new
		at: 'type' put: self class webSTType asString;
		at: 'label' put: self changeString;
		at: 'project' put: 'self projectName';
		at: 'timestamp' put: DateAndTime now asString;
		at: 'author' put: Author uniqueInstance fullName;
		yourself
]

{ #category : #'*Webside' }
RBRefactoryChange class >> classForWebsideJson: json [
	^ self allSubclasses
		detect: [ :c | c acceptsWebsideJson: json ]
		ifNone: nil
]

{ #category : #'*Webside' }
RBRefactoryChange class >> fromWebsideJson: json [
	| class |
	class := self classForWebsideJson: json.
	^ class new fromWebsideJson: json
]

{ #category : #'*Webside' }
RBRefactoryChange >> fromWebsideJson: json [
]

{ #category : #'*Webside' }
RBRefactoryChange class >> webSTType [
	^nil
]