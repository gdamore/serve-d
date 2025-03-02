module served.utils.events;

/// Called for requests (not notifications) from the client to the server. This
/// UDA must be used at most once per method for regular methods. For methods
/// returning arrays (T[]) it's possible to register multiple functions with the
/// same method. In this case, if the client supports it, partial results will
/// be sent for each returning method, meaning the results are streamed. In case
/// the client does not support partial methods, all results will be
/// concatenated together and returned as one.
struct protocolMethod
{
	string method;
}

/// Called after the @protocolMethod for this method is handled. May have as
/// many handlers registered as needed. When the actual protocol method is a
/// partial method (multiple handlers, returning array) this will be ran on each
/// chunk returned by every handler. In that case the handler will be run
/// multiple times on different fibers.
struct postProtocolMethod
{
	string method;
}

/// UDA to annotate a request or notification parameter with to supress linting
/// warnings.
enum nonStandard;

struct protocolNotification
{
	string method;
}

struct EventProcessorConfig
{
	string[] allowedDuplicateMethods = ["object", "served", "std", "io", "workspaced", "fs"];
}

/// Implements the event processor for a given extension module exposing a
/// `members` field defining all potential methods.
mixin template EventProcessor(alias ExtensionModule, EventProcessorConfig config = EventProcessorConfig.init)
{
	static if (__traits(compiles, { import core.lifetime : forward; }))
		import core.lifetime : forward;
	else
		import std.functional : forward;

	import served.lsp.protocol;

	import std.algorithm;
	import std.meta;
	import std.traits;

	// duplicate method name check to avoid name clashes and unreadable error messages
	private string[] findDuplicates(string[] fields)
	{
		string[] dups;
		Loop: foreach (i, field; fields)
		{
			static foreach (allowed; config.allowedDuplicateMethods)
				if (field == allowed)
					continue Loop;

			if (fields[0 .. i].canFind(field) || fields[i + 1 .. $].canFind(field))
				dups ~= field;
		}
		return dups;
	}

	enum duplicates = findDuplicates([ExtensionModule.members]);
	static if (duplicates.length > 0)
	{
		pragma(msg, "duplicates: ", duplicates);
		static assert(false, "Found duplicate method handlers of same name");
	}

	enum lintWarnings = ctLintEvents();
	static if (lintWarnings.length > 0)
		pragma(msg, lintWarnings);

	private string ctLintEvents()
	{
		import std.string : chomp;

		static bool isInvalidMethodName(string methodName, AllowedMethods[] allowed)
		{
			if (!allowed.length)
				return false;

			foreach (a; allowed)
				foreach (m; a.methods)
					if (m == methodName)
						return false;
			return true;
		}

		static string formatMethodNameWarning(string methodName, AllowedMethods[] allowed,
			string codeName, string file, size_t line, size_t column)
		{
			import std.conv : to;

			string allowedStr = "";
			foreach (allow; allowed)
			{
				foreach (m; allow.methods)
				{
					if (allowedStr.length)
						allowedStr ~= ", ";
					allowedStr ~= "`" ~ m ~ "`";
				}
			}

			return "\x1B[1m" ~ file ~ "(" ~ line.to!string ~ "," ~ column.to!string ~ "): \x1B[1;34mHint: \x1B[m"
				~ "method " ~ codeName ~ " listens for event `" ~ methodName
				~ "`, but the type has set allowed methods to " ~ allowedStr
				~ ".\n\t\tNote: check back with the LSP specification, in case this is wrongly tagged or annotate parameter with @nonStandard.\n";
		}

		string lintResult;
		foreach (name; ExtensionModule.members)
		{
			static if (__traits(compiles, __traits(getMember, ExtensionModule, name)))
			{
				// AliasSeq to workaround AliasSeq members
				alias symbols = AliasSeq!(__traits(getMember, ExtensionModule, name));
				static if (symbols.length == 1 && hasUDA!(symbols[0], protocolMethod))
					enum methodName = getUDAs!(symbols[0], protocolMethod)[0].method;
				else static if (symbols.length == 1 && hasUDA!(symbols[0], protocolNotification))
					enum methodName = getUDAs!(symbols[0], protocolNotification)[0].method;
				else
					enum methodName = "";

				static if (methodName.length)
				{
					alias symbol = symbols[0];
					static if (isSomeFunction!(symbol) && __traits(getProtection, symbol) == "public")
					{
						alias P = Parameters!symbol;
						static if (P.length == 1 && is(P[0] == struct)
							&& staticIndexOf!(nonStandard, __traits(getAttributes, P)) == -1)
						{
							enum allowedMethods = getUDAs!(P[0], AllowedMethods);
							static if (isInvalidMethodName(methodName, [allowedMethods]))
								lintResult ~= formatMethodNameWarning(methodName, [allowedMethods],
									name, __traits(getLocation, symbol));
						}
					}
				}
			}
		}

		return lintResult.chomp("\n");
	}

	/// Calls all protocol methods in `ExtensionModule` matching a certain method
	/// and method type.
	/// Params:
	///  UDA = The UDA to filter the methods with. This must define a string member
	///     called `method` which is compared with the runtime `method` argument.
	///  callback = The callback which is called for every matching function with
	///     the given UDA and method name. Called with arguments `(string name,
	///     void delegate() callSymbol, UDA uda)` where the `callSymbol` function is
	///     a parameterless function which automatically converts the JSON params
	///     and additional available arguments based on the method overload and
	///     calls it.
	///  returnFirst = If `true` the callback will be called at most once with any
	///     unspecified matching method. If `false` the callback will be called with
	///     all matching methods.
	///  method = the runtime method name to compare the UDA names with
	///  params = the JSON arguments for this protocol event, automatically
	///     converted to method arguments on demand.
	///  availableExtraArgs = static extra arguments available to pass to the method
	///     calls. `out`, `ref` and `lazy` are perserved given the method overloads.
	///     overloads may consume anywhere between 0 to Args.length of these
	///     arguments.
	/// Returns: `true` if any method has been called, `false` otherwise.
	bool emitProtocol(alias UDA, alias callback, bool returnFirst, Args...)(string method,
			string params, Args availableExtraArgs)
	{
		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			if (uda.method == method)
			{
				debug (PerfTraceLog) mixin(traceStatistics(uda.method ~ ":" ~ name));

				alias symbolArgs = Parameters!symbol;

				auto callSymbol()
				{
					static if (symbolArgs.length == 0)
					{
						return symbol();
					}
					else static if (symbolArgs.length == 1)
					{
						return symbol(params.deserializeJson!(symbolArgs[0]));
					}
					else static if (availableExtraArgs.length > 0
						&& symbolArgs.length <= 1 + availableExtraArgs.length)
					{
						return symbol(params.deserializeJson!(symbolArgs[0]), forward!(
							availableExtraArgs[0 .. symbolArgs.length + -1]));
					}
					else
					{
						static assert(0, "Function for " ~ name ~ " can't have more than one argument");
					}
				}

				callback(name, &callSymbol, uda);
				return true;
			}
			else
				return false;
		}, returnFirst);
	}

	/// Same as emitProtocol, but for the callback instead of getting a delegate
	/// to call, you get a function pointer and a tuple with the arguments for
	/// each instantiation that can be expanded.
	///
	/// So the callback gets called like `callback(name, symbol, arguments, uda)`
	/// and the implementation can then call the symbol function using
	/// `symbol(arguments.expand)`.
	///
	/// This works around scoping issues and copies the arguments once more on
	/// invocation, causing ref/out parameters to get lost however. Allows to
	/// copy the arguments to other fibers for parallel processing.
	bool emitProtocolRaw(alias UDA, alias callback, bool returnFirst)(string method,
			string params)
	{
		import std.typecons : tuple;

		T parseParam(T)()
		{
			import served.lsp.protocol;

			try
			{
				if (params.length && params.ptr[0] == '[')
				{
					// positional parameter support
					// only supports passing a single argument
					string got;
					params.visitJsonArray!((item) {
						if (!got.length)
							got = item;
						else
							throw new Exception("Mismatched parameter count");
					});
					return got.deserializeJson!T;
				}
				else if (params.length && params.ptr[0] == '{')
				{
					// named parameter support
					// only supports passing structs (not parsing names of D method arguments)
					return params.deserializeJson!T;
				}
				else
				{
					// no parameters passed - parse empty JSON for the type or
					// use default value.
					static if (is(T == struct))
						return `{}`.deserializeJson!T;
					else
						return T.init;
				}
			}
			catch (Exception e)
			{
				ResponseError error;
				error.code = ErrorCode.invalidParams;
				error.message = "Failed converting input parameter `" ~ params ~ "` to needed type `" ~ T.stringof ~ "`: " ~ e.msg;
				error.data = JsonValue(e.toString);
				throw new MethodException(error);
			}
		}

		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			if (uda.method == method)
			{
				debug (PerfTraceLog) mixin(traceStatistics(uda.method ~ ":" ~ name));

				alias symbolArgs = Parameters!symbol;

				static if (symbolArgs.length == 0)
				{
					auto arguments = tuple();
				}
				else static if (symbolArgs.length == 1)
				{
					auto arguments = tuple(parseParam!(symbolArgs[0]));
				}
				else static if (availableExtraArgs.length > 0
					&& symbolArgs.length <= 1 + availableExtraArgs.length)
				{
					auto arguments = tuple(parseParam!(symbolArgs[0]), forward!(
						availableExtraArgs[0 .. symbolArgs.length + -1]));
				}
				else
				{
					static assert(0, "Function for " ~ name ~ " can't have more than one argument");
				}

				callback(name, symbol, arguments, uda);
				return true;
			}
			else
				return false;
		}, returnFirst);
	}

	bool emitExtensionEvent(alias UDA, Args...)(Args args)
	{
		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			symbol(forward!args);
			return true;
		}, false);
	}

	/// Iterates through all public methods in `ExtensionModule` annotated with the
	/// given UDA. For each matching function the callback paramter is called with
	/// the arguments being `(string name, Delegate symbol, UDA uda)`. `callback` is
	/// expected to return a boolean if the UDA values were a match.
	///
	/// Params:
	///  UDA = The UDA type to filter methods with. Methods can just have an UDA
	///     with this type and any values. See $(REF getUDAs, std.traits)
	///  callback = Called for every matching method. Expected to have 3 arguments
	///     being `(string name, Delegate symbol, UDA uda)` and returning `bool`
	///     telling if the uda values were a match or not. The Delegate is most
	///     often a function pointer to the given symbol and may differ between all
	///     calls.
	///
	///     If the UDA is a symbol and not a type (such as some enum manifest
	///     constant), then the UDA argument has no meaning and should not be used.
	///  returnFirst = if `true`, once callback returns `true` immediately return
	///     `true` for the whole function, otherwise `false`. If this is set to
	///     `false` then callback will be run on all symbols and this function
	///     returns `true` if any callback call has returned `true`.
	/// Returns: `true` if any callback returned `true`, `false` otherwise or if
	///     none were called. If `returnFirst` is set this function returns after
	///     the first successfull callback call.
	bool iterateExtensionMethodsByUDA(alias UDA, alias callback, bool returnFirst)()
	{
		bool found = false;
		foreach (name; ExtensionModule.members)
		{
			static if (__traits(compiles, __traits(getMember, ExtensionModule, name)))
			{
				// AliasSeq to workaround AliasSeq members
				alias symbols = AliasSeq!(__traits(getMember, ExtensionModule, name));
				static if (symbols.length == 1 && hasUDA!(symbols[0], UDA))
				{
					alias symbol = symbols[0];
					static if (isSomeFunction!(symbol) && __traits(getProtection, symbol) == "public")
					{
						static if (__traits(compiles, { enum uda = getUDAs!(symbol, UDA)[0]; }))
							enum uda = getUDAs!(symbol, UDA)[0];
						else
							enum uda = null;

						static if (returnFirst)
						{
							if (callback(name, &symbol, uda))
								return true;
						}
						else
						{
							if (callback(name, &symbol, uda))
								found = true;
						}
					}
				}
			}
		}

		return found;
	}
}
