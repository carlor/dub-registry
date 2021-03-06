module app;

import github;
import registry;

import std.algorithm : sort;
import std.file;
import std.path;
import userman.web;
import vibe.d;

class DubRegistryWebFrontend {
	private {
		DubRegistry m_registry;
		UserManWebInterface m_usermanweb;
	}

	this(DubRegistry registry, UserManController userman)
	{
		m_registry = registry;
		m_usermanweb = new UserManWebInterface(userman);
	}

	void register(UrlRouter router)
	{
		m_usermanweb.register(router);

		// user front end
		router.get("/", &showHome);
		router.get("/usage", staticTemplate!"usage.dt");
		router.get("/download", &showDownloads);
		router.get("/publish", staticTemplate!"publish.dt");
		router.get("/develop", staticTemplate!"develop.dt");
		router.get("/package-format", staticTemplate!"package_format.dt");
		router.get("/available", &showAvailable);
		router.get("/packages/:packname", &showPackage); // HTML or .json
		router.get("/packages/:packname/:version", &showPackageVersion); // HTML or .zip or .json
		router.get("/view_package/:packname", &redirectViewPackage);
		router.get("/my_packages", m_usermanweb.auth(toDelegate(&showMyPackages)));
		router.get("/my_packages/add", m_usermanweb.auth(toDelegate(&showAddPackage)));
		router.post("/my_packages/add", m_usermanweb.auth(toDelegate(&addPackage)));
		router.post("/my_packages/remove", m_usermanweb.auth(toDelegate(&showRemovePackage)));
		router.post("/my_packages/remove_confirm", m_usermanweb.auth(toDelegate(&removePackage)));
		router.get("*", serveStaticFiles("./public"));
	}

	void showAvailable(HttpServerRequest req, HttpServerResponse res)
	{
		res.writeJsonBody(m_registry.availablePackages);
	}

	void showHome(HttpServerRequest req, HttpServerResponse res)
	{
		// collect the package list
		Json[] packages;
		foreach( pack; m_registry.availablePackages ){
			auto packinfo = m_registry.getPackageInfo(pack);
			packages ~= packinfo;
		}

		// sort by date of last version
		string getDate(Json p){
			if( p.versions.length == 0 ) return null;
			return p.versions[p.versions.length-1].date.get!string;
		}
		sort!((a, b) => getDate(a) > getDate(b))(packages);

		res.renderCompat!("home.dt",
			HttpServerRequest, "req",
			Json[], "packages")(req, packages);
	}

	void showDownloads(HttpServerRequest req, HttpServerResponse res)
	{
		static struct DownloadFile {
			string fileName;
		}

		static struct DownloadVersion {
			string id;
			DownloadFile[string] files;
		}

		static struct Info {
			DownloadVersion[] versions;
			void addFile(string ver, string platform, string filename)
			{
				auto df = DownloadFile(filename);
				foreach(ref v; versions)
					if( v.id == ver ){
						v.files[platform] = df;
						return;
					}
				DownloadVersion dv = DownloadVersion(ver);
				dv.files[platform] = df;
				versions ~= dv;
			}
		}

		Info info;

		foreach(de; dirEntries("public/files", "*.{zip,gz}", SpanMode.shallow)){
			auto name = Path(de.name).head.toString();
			auto basename = stripExtension(name);
			auto parts = basename.split("-");
			if( parts.length != 4 ) continue;
			if( parts[0] != "dub" ) continue;
			info.addFile(parts[1], parts[2]~"-"~parts[3], name);
		}

		info.versions.sort!((a, b) => vcmp(a.id, b.id))();

		res.renderCompat!("download.dt",
			HttpServerRequest, "req",
			Info*, "info")(req, &info);
	}

	void redirectViewPackage(HttpServerRequest req, HttpServerResponse res)
	{
		res.redirect("/packages/"~req.params["packname"]);
	}

	void showPackage(HttpServerRequest req, HttpServerResponse res)
	{
		bool json = false;
		auto pname = req.params["packname"];
		if( pname.endsWith(".json") ){
			pname = pname[0 .. $-5];
			json = true;
		}

		Json pack = m_registry.getPackageInfo(pname);
		if( pack == null ) return;

		if( json ){
			res.writeJsonBody(pack);
		} else {
			res.renderCompat!("view_package.dt",
				HttpServerRequest, "req", 
				Json, "pack",
				string, "ver")(req, pack, "");
		}
	}

	void showPackageVersion(HttpServerRequest req, HttpServerResponse res)
	{
		Json pack = m_registry.getPackageInfo(req.params["packname"]);
		if( pack == null ) return;

		auto ver = req.params["version"];
		string ext;
		if( ver.endsWith(".zip") ) ext = "zip", ver = ver[0 .. $-4];
		else if( ver.endsWith(".json") ) ext = "json", ver = ver[0 .. $-5];

		foreach( v; pack.versions )
			if( v["version"].get!string == ver ){
				if( ext == "zip" ){
					res.redirect(v.downloadUrl.get!string);
				} else if( ext == "json"){
					res.writeJsonBody(v);
				} else {
					res.renderCompat!("view_package.dt",
						HttpServerRequest, "req", 
						Json, "pack",
						string, "ver")(req, pack, v["version"].get!string);
				}
				return;
			}
	}

	void showMyPackages(HttpServerRequest req, HttpServerResponse res, User user)
	{
		res.renderCompat!("my_packages.dt",
			HttpServerRequest, "req",
			User, "user",
			DubRegistry, "registry")(req, user, m_registry);
	}

	void showAddPackage(HttpServerRequest req, HttpServerResponse res, User user)
	{
		res.renderCompat!("add_package.dt",
			HttpServerRequest, "req",
			User, "user",
			DubRegistry, "registry")(req, user, m_registry);
	}

	void addPackage(HttpServerRequest req, HttpServerResponse res, User user)
	{
		Json rep = Json.EmptyObject;
		rep["kind"] = req.form["kind"];
		rep["owner"] = req.form["owner"];
		rep["project"] = req.form["project"];
		m_registry.addPackage(rep, user._id);

		res.redirect("/my_packages");
	}

	void showRemovePackage(HttpServerRequest req, HttpServerResponse res, User user)
	{
		res.renderCompat!("remove_package.dt",
			HttpServerRequest, "req",
			User, "user")(req, user);
	}

	void removePackage(HttpServerRequest req, HttpServerResponse res, User user)
	{
		m_registry.removePackage(req.form["package"], user._id);
		res.redirect("/my_packages");
	}
}

Task s_checkTask;
DubRegistry s_registry;

void startMonitoring()
{
	void monitorNewVersions()
	{
		while(true){
			s_registry.checkForNewVersions();
			sleep(15.minutes());
		}
	}
	s_checkTask = runTask(&monitorNewVersions);
}

static this()
{
	setLogLevel(LogLevel.None);
	setLogFile("log.txt", LogLevel.Debug);

	GithubRepository.register();

	auto router = new UrlRouter;
	router.get("*", (req, res){ if( !s_checkTask.running ) startMonitoring(); });

	// user management
	auto udbsettings = new UserManSettings;
	udbsettings.serviceName = "DUB registry";
	udbsettings.serviceUrl = "http://registry.vibed.org/";
	udbsettings.serviceEmail = "noreply@vibed.org";
	udbsettings.databaseName = "vpmreg";
	auto userdb = new UserManController(udbsettings);

	// VPM registry
	auto regsettings = new DubRegistrySettings;
	regsettings.pathPrefix = "/";
	regsettings.metadataPath = Path("public/packages");
	s_registry = new DubRegistry(regsettings);

	// web front end
	auto webfrontend = new DubRegistryWebFrontend(s_registry, userdb);
	webfrontend.register(router);
	
	// start the web server
 	auto settings = new HttpServerSettings;
	settings.hostName = "registry.vibed.org";
	settings.bindAddresses = ["127.0.0.1"];
	settings.port = 8005;
	settings.sessionStore = new MemorySessionStore;
	
	listenHttp(settings, router);

	// poll github for new project versions
	startMonitoring();
}
