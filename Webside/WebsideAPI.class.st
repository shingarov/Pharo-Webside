"
Implements the API required by Webside.

WebsideServer allInstances.

WebsideServer new
	baseUri: '/pharo';
	port: 9001;
	start.
"
Class {
	#name : #WebsideAPI,
	#superclass : #Object,
	#instVars : [
		'request',
		'server'
	],
	#classVars : [
		'Debuggers',
		'Evaluations',
		'Objects',
		'Workspaces'
	],
	#category : #'Webside-Base'
}

{ #category : #'evaluation  endpoints' }
WebsideAPI >> activeEvaluations [
	^ self evaluations associations
		collect: [ :a | NeoJSONObject new at: 'id' put: a key asString ; yourself ]
]

{ #category : #'changes endpoints' }
WebsideAPI >> addChange [
	| change author |
	change := self requestedChange.
	change ifNil: [ ^ self badRequest: 'Change not supported' ].
	author := (NeoJSONReader fromString: request entity)
		at: 'author'
		ifAbsent: 'Unknown'.
	Author
		useAuthor: author
		during: [ [ change execute ]
				on: Error , SyntaxErrorNotification
				do: [ :e | ^ self  compilationError: e ] ].
	^ change asWebsideJson
]

{ #category : #private }
WebsideAPI >> badRequest: aString [
	^ZnResponse 
	badRequest: request 
		entity: (ZnEntity textCRLF: aString)
]

{ #category : #private }
WebsideAPI >> bodyAt: aString [
	| json |
	json := NeoJSONReader fromString: request entity.
	^json at: aString ifAbsent: nil 
]

{ #category : #'evaluation  endpoints' }
WebsideAPI >> cancelEvaluation [
	| id evaluation |
	id := self requestedId.
	evaluation := self evaluations at: id ifAbsent: [ ^ self notFound ].
	evaluation terminate.
	self evaluations removeKey: id.
	^ nil
]

{ #category : #'code endpoints' }
WebsideAPI >> categories [
	| class |
	class := self requestedClass.
	class ifNil: [^self notFound].
	^class protocols
]

{ #category : #'changes endpoints' }
WebsideAPI >> changes [
	| author changes |
	author := self queryAt: 'author'.
	changes := EpMonitor current log entries select: [:e | e content isCodeChange].
	changes := #().
	author
		ifNotNil: [ changes := changes select: [ :ch | ch author = author ] ].
	^ changes collect: #asWebsideJson
	

]

{ #category : #'code endpoints' }
WebsideAPI >> classDefinition [
	| class |
	class := self requestedClass.
	class ifNil: [^self notFound].
	^class asWebsideJson
]

{ #category : #private }
WebsideAPI >> classNamed: aString [
	| name metaclass class |
	name := aString.
	metaclass := name endsWith: ' class'.
	metaclass
		ifTrue: [ name := name withoutSuffix: ' class' ].
	class := Smalltalk at: name asSymbol ifAbsent: [ ^ nil 
		].
	^ metaclass
		ifTrue: [ class class ]
		ifFalse: [ class ]
]

{ #category : #private }
WebsideAPI >> classTreeFrom: aClass depth: anInteger [
	| json subclasses depth names |
	names := self queryAt: 'names'.
	json := names = 'true'
		ifTrue: [ NeoJSONObject new
			
				at: 'name' put: aClass name;
				at: 'superclass'
					put: (aClass superclass ifNotNil: [ :c | c name ]); yourself ]
		ifFalse: [ aClass asWebsideJson ].
	(anInteger notNil and: [ anInteger = 0 ])
		ifTrue: [ ^ json ].
	depth := anInteger notNil
		ifTrue: [ anInteger - 1 ].
	subclasses := (aClass subclasses sort: [ :a :b | a name <= b name ])
		collect: [ :c | self classTreeFrom: c depth: depth ].
	json at: 'subclasses' put: subclasses.
	^ json
]

{ #category : #'code endpoints' }
WebsideAPI >> classVariables [
	| class |
	class := self requestedClass.
	class ifNil: [^self notFound].
	^class withAllSuperclasses
		gather: [:c | 
			c classVarNames asArray sort collect: [:v | 
				NeoJSONObject new
					at: 'name' put: v;
					at: 'class' put: c name , ' class';
					yourself]]
]

{ #category : #'code endpoints' }
WebsideAPI >> classes [
	| root tree classes names depth json |
	root := self queryAt: 'root'.
	root := root notNil
		ifTrue: [self classNamed: root]
		ifFalse: [self defaultRootClass].
	root ifNil: [^self notFound].
	tree := self queryAt: 'tree'.
	tree = 'true' ifTrue: [
		depth := self queryAt:'depth'.
		depth notNil ifTrue: [depth := depth asInteger].
		json := self classTreeFrom: root depth: depth.
		^Array with: json].
	classes := root withAllSubclasses.
	names := self queryAt: 'names'.
	names = 'true' ifTrue: [^(classes collect: #name) sort].
	^classes collect: #asWebsideJson
]

{ #category : #private }
WebsideAPI >> compilationError: aCompilationError [
	|  entity |
	entity := ZnStringEntity
		with: (NeoJSONWriter toString: aCompilationError asWebsideJson)
		type:
			(ZnMimeType applicationJson
				charSet: 'utf-8';
				yourself).
	^ (ZnResponse statusCode: 409) entity: entity
]

{ #category : #private }
WebsideAPI >> compiler [
	| compiler context class object workspace index debugger frame |
	compiler := OpalCompiler new.
	context := self bodyAt: 'context'.
	context ifNil: [ ^ compiler ].
	context
		at: 'claat'
		ifPresent: [ :name | 
			class := self classNamed: name.
			^ compiler receiver: class ].
	context
		at: 'object'
		ifPresent: [ :id | 
			object := self objects at: (UUID fromString: id) ifAbsent: nil.
			^ compiler receiver: object ].
	context
		at: 'workspace'
		ifPresent: [ :id | 
			workspace := self workspaces
				at: (UUID fromString: id)
				ifAbsent: [ ^ compiler ].
			^ compiler requestor: workspace ].
	context
		at: 'debugger'
		ifPresent: [ :id | 
			index := context at: 'frame' ifAbsent: [ ^ compiler ].
			debugger := self debuggers
				at: (UUID fromString: id)
				ifAbsent: [ ^ compiler ].
			frame := debugger stack
				at: index asInteger
				ifAbsent: [ ^ compiler ].
			^ compiler receiver: frame receiver].
	^ nil
]

{ #category : #'debugging endpoints' }
WebsideAPI >> createDebugger [
	| id process exception context debugger |
	id := self bodyAt: 'evaluation'.
	id ifNil: [ ^ self notFound ].
	id := UUID fromString: id.
	process := self evaluations at: id ifAbsent: [ ^ self notFound ].
	exception := process suspendedContext exception.
	context := exception signalerContext.
	"process suspendedContext: context."
	debugger := process
		newDebugSessionNamed: exception description
		startedAt: context.
	context selector == #doesNotUnderstand:
		ifTrue: [ context := context sender ].
	debugger restart: context.
	context selector == #halt
		ifTrue: [ debugger
				stepOver;
				stepOver ].
	self debuggers at: id put: debugger.
	^ id asString
]

{ #category : #'workspaces endpoints' }
WebsideAPI >> createWorkspace [
	| id |
	id := self newID.
	self workspaces at: id put: Workspace new.
	^ id asString
]

{ #category : #'debugging endpoints' }
WebsideAPI >> debuggerFrame [
	| debugger index frame interval |
	debugger := self debuggers
		at: self requestedId
		ifAbsent: [ ^ self notFound ].
	index := self requestedIndex.
	frame := debugger stack at: index ifAbsent: [ ^ self notFound ].
	interval := debugger pcRangeForContext: frame.
	interval := NeoJSONObject new
		at: 'start' put: interval first;
		at: 'end' put: interval last;
		yourself.
	^ frame asWebsideJson
		at: 'index' put: index;
		at: 'interval' put: interval;
		yourself
]

{ #category : #'debugging endpoints' }
WebsideAPI >> debuggerFrames [
	| debugger |
	debugger := self debuggers
		at: self requestedId
		ifAbsent: [ ^ self notFound ].
	^ debugger stack
		withIndexCollect: [ :f :i | 
			NeoJSONObject new
				at: 'index' put: i;
				at: 'label' put: f method printString;
				yourself ]
]

{ #category : #private }
WebsideAPI >> debuggers [
	^server debuggers
]

{ #category : #private }
WebsideAPI >> defaultRootClass [
	^Object
]

{ #category : #'debugging endpoints' }
WebsideAPI >> deleteDebugger [
	| id debugger |
	id := self requestedId .
	debugger := self debuggers at: id ifAbsent: nil.
	debugger notNil ifTrue: [ 
		debugger terminate.
		self debuggers removeKey: id ifAbsent: nil.
		self evaluations removeKey: id ifAbsent: nil ].
	^id
]

{ #category : #'workspaces endpoints' }
WebsideAPI >> deleteWorkspace [
	self workspaces removeKey: self requestedId ifAbsent: [^self notFound].
	^ nil
]

{ #category : #'code endpoints' }
WebsideAPI >> dialect [
	^'Pharo'
]

{ #category : #'evaluation  endpoints' }
WebsideAPI >> evaluateExpression [
	| expression sync pin id semaphore block object json process |
	expression := self bodyAt: 'expression'.
	sync := (self bodyAt: 'sync') ifNil: true.
	pin := (self bodyAt: 'pin') ifNil: false.
	id := self newID.
	semaphore := Semaphore new.
	block := [ [ object := self compiler evaluate: expression ]
		on: Exception
		do: [ :exception | 
			semaphore signal.
			process
				suspendedContext: exception signalerContext;
				suspend ].
	self evaluations removeKey: id ifAbsent: nil.
	(sync not or: [ pin ])
		ifTrue: [ self objects at: id put: object ].
	semaphore signal.
	object ].
	process := self evaluations at: id put: block fork.
	sync
		ifTrue: [ semaphore wait.
			object ifNil: [ ^ self evaluationError: id ].
			json := object asWebsideJson.
			pin
				ifTrue: [ json at: 'id' put: id asString ].
			^ json ].
	^ NeoJSONObject new
		at: 'id' put: id asString;
		at: 'expression' put: expression;
		yourself
]

{ #category : #private }
WebsideAPI >> evaluationError: id [
	| process json entity |
	process := self evaluations at: id.
	json := NeoJSONObject new
		at: 'description'
			put: process suspendedContext exception description;
		at: 'evaluation' put: id asString;
		yourself.
	entity := ZnStringEntity
		with: (NeoJSONWriter toString: json)
		type:
			(ZnMimeType applicationJson
				charSet: 'utf-8';
				yourself).
	^ ZnResponse serverErrorWithEntity: entity
]

{ #category : #private }
WebsideAPI >> evaluations [
	^server evaluations
]

{ #category : #private }
WebsideAPI >> filterByCategory: aCollection [
	| category |
	category := self queriedCategory.
	^(category notNil and: [category notEmpty])
		ifTrue: [aCollection select: [:m | m category = category]]
		ifFalse: [aCollection]
]

{ #category : #private }
WebsideAPI >> filterByVariable: aCollection [
	| variable class slot classVar |
	variable := self queriedReferencing.
	variable ifNil: [ ^ aCollection ].
	^ aCollection
		select: [ :m | 
			class := m methodClass.
			(class hasSlotNamed: variable)
				ifTrue: [ slot := class slotNamed: variable ].
			(class classVarNames includes: variable)
				ifTrue: [ classVar := class classVarNamed: variable ].
			(slot notNil and: [ (slot isReadIn: m) or: [ slot isWrittenIn: m ]  ])
				or: [ classVar notNil and: [ classVar isReferencedIn: m ] ] ]
]

{ #category : #'debugging endpoints' }
WebsideAPI >> frameBindings [
	| debugger frame |
	debugger := self debuggers
		at: self requestedId
		ifAbsent: [ ^ self notFound ].
	frame := debugger stack
		at: self requestedIndex
		ifAbsent: [ ^ self notFound ].
	^ frame gtDebuggerRetrieveVariableValuePairs
		collect: [ :b | 
			NeoJSONObject new
				at: 'name' put: b key asString;
				at: 'value' put: b value printString;
				yourself ]
]

{ #category : #private }
WebsideAPI >> implementorsOf: aSymbol [
	| scope |
	scope := self queriedScope.
	^ scope
		ifNotNil: [ scope implementorsOf: aSymbol ]
		ifNil: [ SystemNavigation default allImplementorsOf: aSymbol ]
]

{ #category : #'code endpoints' }
WebsideAPI >> instanceVariables [
	| class |
	class := self requestedClass.
	class ifNil: [^self notFound].
	^class withAllSuperclasses
		gather: [:c | 
			c instVarNames collect: [:v | 
				NeoJSONObject new
					at: 'name' put: v;
					at: 'class' put: c name;
					yourself]]
]

{ #category : #'code endpoints' }
WebsideAPI >> method [
	| class selector |
	class := self requestedClass.
	class ifNil: [ ^ self notFound ].
	selector := self requestedSelector.
	selector ifNil: [ ^ self notFound ].
	(class includesSelector: selector) ifFalse: [ ^ self notFound ].
	^ (class >> selector) asWebsideJson
]

{ #category : #'code endpoints' }
WebsideAPI >> methods [
	| selector methods senders global references class |
	selector := self queriedSelector.
	selector notNil
		ifTrue: [ methods := self implementorsOf: selector ].
	selector := self queriedSending.
	selector notNil
		ifTrue: [ senders := self sendersOf: selector.
			methods := methods
				ifNil: [ senders ]
				ifNotNil: [ methods intersection: senders ] ].
	global := self queriedReferencingClass.
	global notNil
		ifTrue: [ references := self referencesTo: global.
			methods := methods
				ifNil: [ references ]
				ifNotNil: [ methods intersection: references ] ].
	class := self requestedClass ifNil: [ self queriedClass ].
	(class notNil and: [ methods notNil ])
		ifTrue: [ methods := methods select: [ :m | m methodClass == class ] ].
	methods
		ifNil: [ methods := (class ifNil: [ self defaultRootClass ]) methodDictionary
				asArray ].
	methods := self filterByCategory: methods.
	methods := self filterByVariable: methods.
	^ methods collect: #asWebsideJson
]

{ #category : #private }
WebsideAPI >> newID [
	^UUID new
]

{ #category : #private }
WebsideAPI >> notFound [
	^ZnResponse notFound: 'resource not found'
]

{ #category : #private }
WebsideAPI >> objects [
	^server objects
]

{ #category : #'objects endpoints' }
WebsideAPI >> pinnedObject [
	| id object  |
	id := self requestedId.
	self evaluations
		at: id
		ifPresent: [ :process | 
			process isSuspended
				ifTrue: [ ^ self evaluationError: id ] ].
	object := self objects at: id ifAbsent: [ ^ self notFound ].
	^ object asWebsideJson
		at: 'id' put: id asString;
		yourself
]

{ #category : #'objects endpoints' }
WebsideAPI >> pinnedObjectSlot [
	
	| id object path index |
	id := self requestedId.
	object := self objects at: id ifAbsent: [ ^ self notFound ].
	path := request url segments.
	index := path indexOf: 'objects'.
	path
		from: index + 2
		to: path size
		do:
			[ :s | object := self slot: s of: object ifAbsent: [ ^ self notFound ] ].
	^ object asWebsideJson
]

{ #category : #'objects endpoints' }
WebsideAPI >> pinnedObjects [
	^ self objects
		associations collect: [ :a | 
			a value asWebsideJson
				at: 'id' put: a key asString;
				yourself ]
]

{ #category : #'code endpoints' }
WebsideAPI >> project [
	| package |
	package := self requestedProject.
	package ifNil: [ ^ self notFound ].
	^package asWebsideJson 
]

{ #category : #'code endpoints' }
WebsideAPI >> projects [
	| organizer root packages names |
	organizer := RPackageOrganizer default .
	root := self queryAt: 'root'.
	root := root notNil
		ifTrue: [ organizer packageNamed: root ifAbsent: nil ].
	packages := root notNil
		ifTrue: [ {root} ]
		ifFalse: [ organizer packages ].
	names := self queryAt: 'names'.
	names = 'true'
		ifTrue: [ ^ (packages collect: #name) sort ].
	^ packages collect: #asWebsideJson
]

{ #category : #private }
WebsideAPI >> queriedCategory [
	| category |
	category := request at: 'category' ifAbsent: nil.
	^category ifNotNil: [category asSymbol]
]

{ #category : #private }
WebsideAPI >> queriedClass [
	| name |
	name := request at: 'class' ifAbsent: nil.
	^name ifNotNil: [self classNamed: name]
]

{ #category : #private }
WebsideAPI >> queriedReferencing [
	^ self queriedReferencingClass isNil
		ifTrue: [ self queryAt: 'referencing' ]
]

{ #category : #private }
WebsideAPI >> queriedReferencingClass [
	| name |
	name := self queryAt: 'referencing'.
	^ name ifNotNil: [ self classNamed: name ]
]

{ #category : #private }
WebsideAPI >> queriedScope [
	| scope |
	scope := request at: 'scope' ifAbsent: nil.
	^ scope ifNotNil: [ self classNamed: scope ]
]

{ #category : #private }
WebsideAPI >> queriedSelector [
	| selector |
	selector := request at: 'selector' ifAbsent: nil.
	^selector ifNotNil: [selector asSymbol]
]

{ #category : #private }
WebsideAPI >> queriedSending [
	| selector |
	selector := request at: 'sending' ifAbsent: nil.
	^selector ifNotNil: [selector asSymbol]
]

{ #category : #private }
WebsideAPI >> queryAt: aString [
	^request at: aString ifAbsent: nil.
]

{ #category : #private }
WebsideAPI >> referencesTo: aClass [
	| binding |
	binding := Smalltalk bindingOf: aClass name asSymbol.
	^SystemNavigation default allReferencesTo: binding
]

{ #category : #accessing }
WebsideAPI >> request: aTeaRequest [ 
	request := aTeaRequest
]

{ #category : #private }
WebsideAPI >> requestedChange [
	| json change |
	json := NeoJSONReader fromString: request entity.
	change := RBRefactoryChange fromWebsideJson: json.
   change ifNil: [ change := RBRefactoring fromWebsideJson: json ].
	^ change
]

{ #category : #private }
WebsideAPI >> requestedClass [
	| name |
	name := self urlAt: 'name'.
	^ name ifNotNil: [ self classNamed: name ]
]

{ #category : #private }
WebsideAPI >> requestedContext [
	| context name id debugger index |
	context := self bodyAt: 'context'.
	context ifNil: [ ^ nil ].
	name := context at: 'class' ifAbsent: nil.
	name ifNotNil: [ ^ self classNamed: name ].
	id := context at: 'object' ifAbsent: nil.
	id
		ifNotNil: [ id := UUID fromString: id.
			^ self objects at: id ifAbsent: nil ].
	id := context at: 'workspace' ifAbsent: nil.
	id
		ifNotNil: [ id := UUID fromString: id.
			^ self workspaces at: id ifAbsent: nil ].
	id := context at: 'debugger' ifAbsent: nil.
	id
		ifNotNil: [ id := UUID fromString: id.
			debugger := self debuggers at: id ifAbsent: [ ^ nil ].
			index := context at: 'frame' ifAbsent: [ ^ nil ].
			^debugger stack at: index asInteger ifAbsent: [ ^ nil ].].
	^ nil
]

{ #category : #private }
WebsideAPI >> requestedId [
	| id |
	id := self urlAt: 'id'.
	^ id ifNotNil: [ UUID fromString: id]
]

{ #category : #private }
WebsideAPI >> requestedIndex [
	| index |
	index := self urlAt: 'index'.
	^ index ifNotNil: [ index asInteger ]
]

{ #category : #private }
WebsideAPI >> requestedProject [
	| name |
	name := self urlAt: 'name'.
	^ name ifNotNil: [ RPackageOrganizer default packageNamed: name ifAbsent: nil  ]
]

{ #category : #private }
WebsideAPI >> requestedSelector [
	| selector |
	selector := self urlAt: 'selector'.
	^ selector ifNotNil: [ selector asSymbol ]
]

{ #category : #'debugging endpoints' }
WebsideAPI >> restartDebugger [
	| debugger context update method |
	debugger := self debuggers
		at: self requestedId
		ifAbsent: [ ^ self notFound ].
	context := debugger stack
		at: self requestedIndex
		ifAbsent: [ ^ self notFound ].
	update := self queryAt: 'update'.
	method := context method.
	(update = 'true' and: [ method notNil ])
		ifTrue: [ context privRefreshWith: method classBinding value >> method selector ].
	debugger restart: context.
	^ nil
]

{ #category : #'debugging endpoints' }
WebsideAPI >> resumeDebugger [
	| id debugger |
	id := self requestedId.
	debugger := self debuggers at: id ifAbsent: [ ^ self notFound ].
	self debuggers removeKey: id.
	debugger resume.
		^ nil
]

{ #category : #private }
WebsideAPI >> sendersOf: aSymbol [
	| scope |
	scope := self queriedScope.
	^ scope
		ifNotNil: [ scope sendersOf: aSymbol ]
		ifNil: [ SystemNavigation default allSendersOf: aSymbol ]
]

{ #category : #accessing }
WebsideAPI >> server: aWebsideServer [
	server := aWebsideServer
]

{ #category : #private }
WebsideAPI >> slot: aString of: anObject ifAbsent: aBlock [
	| index |
	aString asInteger asString = aString ifTrue: [ 
		index := aString asInteger.
		anObject isCollection
			ifTrue: [ 
				index > anObject size ifTrue: [ ^aBlock value ].
				^[anObject at: index] on: Error do: [ anObject basicAt: index ] ] 
			ifFalse: [
				anObject class isVariable ifTrue: [^anObject at: index].
				index > anObject class instSize ifTrue: [^aBlock value].
				^anObject instVarAt: index]].
		^(anObject class allInstVarNames includes: aString)
			ifTrue:[anObject instVarNamed: aString] ifFalse: [ aBlock value ]
]

{ #category : #'debugging endpoints' }
WebsideAPI >> stepIntoDebugger [
	| debugger context |
	debugger := self debuggers
		at: self requestedId
		ifAbsent: [ ^ self notFound ].
	context := debugger stack
		at: self requestedIndex
		ifAbsent: [ ^ self notFound ].
	debugger stepInto: context.
		^ nil
]

{ #category : #'debugging endpoints' }
WebsideAPI >> stepOverDebugger [
	| debugger context |

	debugger := self debuggers
		at: self requestedId
		ifAbsent: [ ^ self notFound ].
	context := debugger stack
		at: self requestedIndex
		ifAbsent: [ ^ self notFound ].
	debugger stepOver: context.
	^ nil
]

{ #category : #'code endpoints' }
WebsideAPI >> subclasses [
| class |
class := self requestedClass .
class ifNil: [ ^ self notFound  ].
^ class subclasses collect: #asWebsideJson 
]

{ #category : #'debugging endpoints' }
WebsideAPI >> terminateDebugger [
	| id debugger |
	id := self requestedId.
	debugger := self debuggers at: id ifAbsent: [ ^ self notFound ].
	self debuggers removeKey: id.
	debugger terminate.
		^nil
]

{ #category : #'objects endpoints' }
WebsideAPI >> unpinObject [

	self objects removeKey: self requestedId ifAbsent: [ ^ self notFound ].
	^ nil
]

{ #category : #private }
WebsideAPI >> urlAt: aString [
	^request at: aString ifAbsent: nil
]

{ #category : #'code endpoints' }
WebsideAPI >> variables [
	| class |
	class := self requestedClass.
	class ifNil: [ ^ self notFound ].
	^ self instanceVariables , self classVariables
]

{ #category : #private }
WebsideAPI >> workspaces [
	^server workspaces
]
