Extension { #name : #RBMethodRefactoring }

{ #category : #'*Webside' }
RBMethodRefactoring >> asWebsideJson [
	^ super asWebsideJson
		at: 'class' put: class name;
		yourself
]

{ #category : #'*Webside' }
RBMethodRefactoring >> fromWebsideJson: json [
	super fromWebsideJson: json.
	class := json at: 'class' ifAbsent: nil.
	class ifNotNil: [class := self classObjectFor: class asSymbol].
]
