import React from "react";
import logo from "../../assets/logo.jpeg";

const Header = () => {
	return (
		<nav className="bg-white shadow-md px-4 pb-8 pt-2">
			<div className="relative ml-8">
				<img src={logo} alt="Videolution Logo" className="h-auto w-10 ml-4" />
				<span className="absolute text-2xl font-bold text-gray-800 ml-3 -bottom-3 left-8 font-alexandria ">
					Video
				</span>
				<span className="absolute text-sm font-medium text-gray-800 -bottom-6 left-32 font-inter">
					Verse
				</span>
			</div>
		</nav>
	);
};

export default Header;
