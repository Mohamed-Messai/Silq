// Written in the D programming language
// License: http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0

import std.array, std.algorithm, std.conv, std.exception;
import lexer, type, expression, scope_, util;

abstract class Declaration: Expression{
	Identifier name;
	Scope scope_;
	this(Identifier name){ this.name=name; }
	override @property string kind(){ return "declaration"; }
	final @property string getName(){ return (rename?rename:name).name; }
	override string toString(){ return getName; }

	bool isLinear(){ return true; }

	mixin VariableFree;
	override int componentsImpl(scope int delegate(Expression) dg){ return 0; }

	// semantic information
	Identifier rename=null;
	int semanticDepth=0;
}

class CompoundDecl: Expression{
	Expression[] s;
	this(Expression[] ss){s=ss;}
	override CompoundDecl copyImpl(CopyArgs args){
		return new CompoundDecl(s.map!(s=>s.copy(args)).array);
	}

	override string toString(){return "{\n"~indent(join(map!(a=>a.toString()~(a.isCompound()?"":";"))(s),"\n"))~"\n}";}
	override bool isCompound(){ return true; }
	override int componentsImpl(scope int delegate(Expression) dg){ return 0; }

	// semantic information
	AggregateScope ascope_;

	mixin VariableFree; // TODO!
}



class VarDecl: Declaration{
	Expression dtype;
	bool isConst;
	this(Identifier name){ super(name); }
	override VarDecl copyImpl(CopyArgs args){
		enforce(!args.preserveSemantic,"TODO");
		//return new VarDecl(dtype.copy(args));
		auto r=new VarDecl((rename?rename:name).copy(args));
		if(dtype) r.dtype=dtype.copy(args);
		return r;
	}
	override string toString(){ return getName~(dtype?": "~dtype.toString():vtype?": "~vtype.toString():""); }
	@property override string kind(){ return "variable"; }

	override bool isLinear(){
		return vtype&&!vtype.isClassical();
	}
	// semantic information
	Expression vtype;
	Expression initializer;
	Expression typeConstBlocker=null;
}

class Parameter: VarDecl{
	this(bool isConst, Identifier name, Expression type){
		super(name); this.dtype=type;
		this.isConst=isConst;
	}
	override Parameter copyImpl(CopyArgs args){
		enforce(!args.preserveSemantic,"TODO");
		return new Parameter(isConst,(rename?rename:name).copy(args),dtype);
	}
	override bool isLinear(){
		return !isConst&&(!vtype||!vtype.isClassical());
	}
	override string toString(){ return getName~(dtype?": "~dtype.toString():""); }
	@property override string kind(){ return "parameter"; }
}

class FunctionDef: Declaration{
	Parameter[] params;
	bool isTuple;
	Expression rret;
	CompoundExp body_;
	bool isSquare=false;
	auto annotation=Annotation.none;
	this(Identifier name, Parameter[] params, bool isTuple, Expression rret, CompoundExp body_)in{
		assert(isTuple||params.length==1);
	}body{
		super(name); this.params=params; this.isTuple=isTuple; this.rret=rret; this.body_=body_;
	}
	override FunctionDef copyImpl(CopyArgs args){
		enforce(!args.preserveSemantic,"TODO");
		return new FunctionDef((rename?rename:name?name:null).copy(args),params.map!(p=>p.copy(args)).array,isTuple,rret?rret.copy(args):null,body_?body_.copy(args):null);
	}
	override string toString(){
		string d=isSquare?"[]":"()";
		return "def "~(name?getName:"")~d[0]~join(map!(to!string)(params),",")~(isTuple&&params.length==1?",":"")~d[1]~(annotation?text(annotation):"")~(body_?body_.toString():";");
	}

	override bool isCompound(){ return true; }
	override bool isLinear(){ return ftype && !ftype.isClassical(); }

	@property override string kind(){ return "function"; }

	// semantic information
	FunctionScope fscope_;
	VarDecl context;
	VarDecl contextVal;
	VarDecl thisVar; // for constructors
	Identifier[] captures;
	void addCapture(Identifier id){
		captures~=id;
	}
	@property string contextName()in{assert(!!context);}body{ return context.getName; }
	Expression ret; // return type
	FunTy ftype;
	bool hasReturn;
	bool isConstructor;
	string[] retNames;

	@property Scope realScope(){
		if(isConstructor) return scope_.getDatDecl().scope_;
		return scope_;
	}
	@property bool isNested(){ return !!cast(NestedScope)realScope; }

	@property size_t numArgs(){
		if(!ftype) return 0;
		return ftype.dom.numComponents;
	}

	@property size_t numReturns(){
		if(!ftype) return 0;
		return ftype.cod.numComponents;
	}
}


enum Variance{
	invariant_,
	covariant,
	contravariant,
}

class DatParameter: Parameter{
	Variance variance;
	this(Variance variance, Identifier name, Expression type){
		this.variance=variance;
		super(false,name,type);
	}
	override DatParameter copyImpl(CopyArgs args){
		return new DatParameter(variance,(rename?rename:name).copy(args),dtype.copy(args));
	}
	override string toString(){
		final switch(variance)with(Variance){
			case invariant_: return super.toString();
			case covariant: return "+"~super.toString();
			case contravariant: return "-"~super.toString();
		}
	}
}

class DatDecl: Declaration{
	AggregateTy dtype;
	bool hasParams;
	DatParameter[] params;
	bool isTuple;
	bool isQuantum;
	CompoundDecl body_;
	this(Identifier name,bool hasParams,DatParameter[] params,bool isTuple,bool isQuantum,CompoundDecl body_)in{
		if(hasParams) assert(isTuple||params.length==1);
		else assert(isTuple&&params.length==0);
	}body{
		super(name);
		this.hasParams=hasParams;
		this.params=params;
		this.isTuple=isTuple;
		this.isQuantum=isQuantum;
		this.body_=body_;
	}
	override DatDecl copyImpl(CopyArgs args){
		return new DatDecl((rename?rename:name).copy(args),hasParams,params.map!(p=>p.copy(args)).array,isTuple,isQuantum,body_.copy(args));
	}
	override string toString(){
		return "dat "~getName~(hasParams?text("[",params.map!(to!string).joiner(","),"]"):"")~body_.toString();
	}

	override bool isCompound(){ return true; }
	override bool isLinear(){ return false; }

	final Expression[string] getSubst(Expression arg){
		Expression[string] subst;
		if(isTuple){
			foreach(i,p;params)
				subst[p.getName]=new IndexExp(arg,[new LiteralExp(Token(Tok!"0",to!string(i)))],false).eval();
		}else{
			assert(params.length==1);
			subst[params[0].getName]=arg;
		}
		return subst;
	}

	// semantic information
	DataScope dscope_;
	VarDecl context;
	@property string contextName()in{assert(!!context);}body{ return context.getName; }
	@property bool isNested(){ return !!cast(NestedScope)scope_; }
}

abstract class DefExp: Expression{
	BinaryExp!(Tok!":=") initializer;
	this(BinaryExp!(Tok!":=") init){ this.initializer=init; }
	abstract VarDecl[] decls();

	abstract void setType(Expression type);
	abstract void setInitializer();
	abstract void setError();

	abstract int varDecls(scope int delegate(VarDecl) dg);
}

class SingleDefExp: DefExp{
	VarDecl decl;
	override VarDecl[] decls(){ return [decl]; }
	this(VarDecl decl, BinaryExp!(Tok!":=") init){
		this.decl=decl; super(init);
	}
	override SingleDefExp copyImpl(CopyArgs args){
		return new SingleDefExp(decl.copy(args),initializer.copy(args));
	}
	override string toString(){
		return initializer.toString();
	}

	override void setType(Expression type){
		assert(!!type);
		decl.vtype=type;
		if(!decl.vtype) decl.sstate=SemState.error;
	}
	override void setInitializer(){
		assert(!decl.initializer&&initializer);
		decl.initializer=initializer.e2;
	}
	override void setError(){
		decl.sstate=sstate=SemState.error;
	}

	override int varDecls(scope int delegate(VarDecl) dg){
		return dg(decl);
	}

	mixin VariableFree; // TODO
	override int componentsImpl(scope int delegate(Expression) dg){
		return 0; // TODO: ok?
	}
}

class MultiDefExp: DefExp{
	VarDecl[] decls_;
	override VarDecl[] decls(){ return decls_; }
	this(VarDecl[] decls_,BinaryExp!(Tok!":=") init){
		this.decls_=decls_; super(init);
	}
	override MultiDefExp copyImpl(CopyArgs args){
		return new MultiDefExp(decls_.map!(d=>d.copy(args)).array,initializer.copy(args));
	}
	override string toString(){
		return initializer.toString();
	}
	override void setType(Expression type){
		assert(!!type);
		if(auto tt=type.isTupleTy()){
			if(tt.length==decls_.length){
				foreach(i,decl;decls_){
					decl.vtype=tt[i];
				}
			}
		}else{
			assert(0,"TODO!");
		}
	}
	override void setInitializer(){
		assert(initializer);
		auto tpl=cast(TupleExp)initializer.e2;
		if(!tpl) return;
		assert(tpl.length==decls.length);
		foreach(i;0..decls.length){
			assert(!decls[i].initializer);
			decls[i].initializer=tpl.e[i];
		}
	}
	override void setError(){
		foreach(decl;decls_) decl.sstate=SemState.error;
		sstate=SemState.error;
	}

	override int varDecls(scope int delegate(VarDecl) dg){
		foreach(decl;decls_) if(auto r=dg(decl)) return r;
		return 0;
	}

	mixin VariableFree;
	override int componentsImpl(scope int delegate(Expression) dg){
		return 0; // TODO: ok?
	}
}

string getActualPath(string path){
	import std.path, file=std.file, options;
	auto ext = path.extension;
	if(ext=="") path = path.setExtension("hql");
	if(file.exists(path)) return path;
	foreach_reverse(p;opt.importPath){
		auto candidate=buildPath(p,path);
		if(file.exists(candidate))
			return candidate;
	}
	return path;
}

class ImportExp: Declaration{
	Expression[] e;
	this(Expression[] e){
		super(null);
		this.e=e;
	}
	override ImportExp copyImpl(CopyArgs args){
		return new ImportExp(e.map!(e=>e.copy(args)).array);
	}
	static string getPath(Expression e){
		static string doIt(Expression e){
			import std.path;
			if(auto i=cast(Identifier)e) return i.name;
			if(auto f=cast(BinaryExp!(Tok!"."))e) return buildPath(doIt(f.e1),doIt(f.e2));
			assert(0);
		}
		return doIt(e);
	}
	override @property string kind(){ return "import declaration"; }
	override string toString(){ return "import "~e.map!(to!string).join(","); }
	override bool isLinear(){ return false; }
}
