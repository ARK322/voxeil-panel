"use client";

export function TopBar() {
  return (
    <header className="bg-white border-b border-gray-200 px-6 py-4 flex items-center justify-between">
      <div>
        <h2 className="text-lg font-semibold text-gray-900">Control Panel</h2>
      </div>
      <div className="flex items-center gap-4">
        <button className="px-4 py-2 text-sm text-gray-700 hover:bg-gray-100 rounded-lg">
          Settings
        </button>
        <button className="px-4 py-2 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-700">
          Logout
        </button>
      </div>
    </header>
  );
}
